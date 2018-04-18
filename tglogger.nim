import algorithm, db_sqlite, future, json, options, os, osproc, posix,
  sequtils, strutils, tables, times

type Color {.pure.} = enum
  normal = "\x1b[0m"
  red = "\x1b[0;31m"
  green = "\x1b[0;32m"
  blue = "\x1b[0;34m"

let color = isatty(1) == 1
template `^`(c: Color): string =
  if color: $c else: ""

var PR_SET_PDEATHSIG {.importc: "PR_SET_PDEATHSIG", header: "<sys/prctl.h>".}: cint

proc prctl(option: cint, arg2: culong = 0, arg3: culong = 0, arg4: culong = 0,
  arg5: culong = 0): cint {.importc, header: "<sys/prctl.h>".}

proc csetenv(name: cstring, value: cstring, override: cint): cint
  {.importc: "setenv", header: "<stdlib.h>".}

proc perror(s: cstring) {.importc, header: "<stdio.h>".}

proc opt(node: JsonNode, key: string): Option[JsonNode] =
  if node.hasKey(key):
    some(node[key])
  else:
    none(JsonNode)

proc extractName(node: JsonNode): (string, string) =
  let firstName = node.opt("first_name").map(x => x.getStr).get("")
  let lastName = node.opt("last_name").map(x => x.getStr).get("")
  let title = node.opt("title").map(x => x.getStr).get("")
  let fullName = if firstName.len > 0 and lastName.len > 0:
      firstName & " " & lastName
    elif firstName.len > 0:
      firstName
    elif title.len > 0:
      title
    else:
      ""
  let username = node.opt("username").map(x => x.getStr(nil)).get(nil)
  (fullName, username)

template nilIfEmpty(s: string): string =
  if s == nil or s.len == 0: nil else: s

proc convert(create: string, handleRow: (DbConn, seq[string]) -> void) =
  let db = open("log.sqlite", "", "", "")

  db.exec("ALTER TABLE log RENAME TO oldlog".sql)
  db.exec(create.sql)

  var index = 0
  var needCommit = false
  for row in db.fastRows("select * from oldlog".sql):
    if index %% 10000 == 0:
      echo("handling ", index)
      db.exec("BEGIN".sql)
      needCommit = true
    index += 1

    handleRow(db, row)

    if index %% 10000 == 0:
      db.exec("COMMIT".sql)
      needCommit = false

  if needCommit:
    db.exec("COMMIT".sql)
  db.exec("DROP TABLE oldlog".sql)
  db.exec("VACUUM".sql)

  db.close()

type Peer = tuple[peerType: int, peerId: int, accessHash: string]

proc hexToInt(c: char): int =
  if c >= '0' and c <= '9':
    c.int - '0'.int
  elif c >= 'a' and c <= 'f':
    c.int - 'a'.int + 10
  else:
    0

proc hexToInt(s: string): BiggestInt =
  result = 0
  for i in 0 .. s.len /% 2 - 1:
    result = result + (hexToInt(s[2 * i]) * 16 + hexToInt(s[2 * i + 1])) shl (i * 8)

proc peer(s: string): Peer =
  let ds = if s[0] == '$': s[1 .. ^1] else: s
  let ws = ds & '0'.repeat(48 - ds.len)
  let peerType = hexToInt(ws[0 .. 7]).int
  let peerId = hexToInt(ws[8 .. 15]).int
  let accessHash = ws[16 .. 47]
  (peerType, peerId, accessHash)

proc id(p: Peer): int64 =
  if p.peerType == 2:
    (-p.peerId).int64
  elif p.peerType == 5:
    -1000000000000 - p.peerId.int64
  else:
    p.peerId

let params = commandLineParams()
if params.len >= 1 and params[0] == "daemon":
  var fd: array[2, cint]
  discard pipe(fd)

  let pid = fork()
  if pid == 0:
    discard close(fd[0])
    discard close(1)
    discard dup(fd[1])
    discard close(fd[1])
    discard close(0)
    discard open("/dev/null")
    discard close(2)
    discard open("/dev/null")
    discard prctl(PR_SET_PDEATHSIG, SIGINT.culong)

    discard csetenv("TELEGRAM_HOME", getCurrentDir(), 1)
    let args = ["telegram-cli", "--json", "-E", "-R"]
    let cexec = allocCStringArray(args)
    let code = execvp(cexec[0], cexec)
    perror("")
    deallocCStringArray(cexec)
    quit(code)
  else:
    discard close(fd[1])
    var linebuf: seq[cchar] = @[]
    var readbuf: array[80, cchar]

    let db = open("log.sqlite", "", "", "")
    db.exec("""CREATE TABLE IF NOT EXISTS log (
      id TEXT PRIMARY KEY NOT NULL,
      target_id LONG NOT NULL,
      from_id LONG NOT NULL,
      from_name TEXT NOT NULL,
      from_username TEXT,
      to_id LONG NOT NULL,
      to_name TEXT NOT NULL,
      to_username TEXT,
      reply_id TEXT,
      forward_id LONG NOT NULL,
      forward_name TEXT,
      forward_username TEXT,
      forward_time LONG NOT NULL,
      time LONG NOT NULL,
      message TEXT
    )""".sql)

    while true:
      let count = read(fd[0], addr(readbuf[0]), readbuf.len)
      if count <= 0:
        break
      var fromIndex = 0
      for i in 0 .. count - 1:
        if readbuf[i] == "\n"[0]:
          linebuf &= readbuf[fromIndex .. i - 1]
          linebuf &= "\0"[0]
          fromIndex = i + 1

          var str: cstring = addr(linebuf[0])

          if str != nil and str[0] == '{':
            try:
              let json = parseJson($str)
              let event = json["event"].getStr
              if event != "online-status":
                let idPeer = json["id"].getStr.peer
                let id = idPeer.accessHash
                let targetId = idPeer.id
                let fromId = json["from"]["id"].getStr.peer.id
                let toId = json["to"]["id"].getStr.peer.id
                let (fromName, fromUsername) = json["from"].extractName
                let (toName, toUsername) = json["to"].extractName
                let replyId = json.opt("reply_id").map(x => x.getStr)
                  .map(x => (if x.len > 0: some(x) else: none(string))).flatten
                  .map(x => x.peer.accessHash).get(nil)
                let forwardId = json.opt("fwd_from").map(x => x["id"].getStr.peer.id).get(0)
                let (forwardName, forwardUsername) = json.opt("fwd_from")
                  .map(x => x.extractName).get((nil, nil))
                let forwardTime = json.opt("fwd_date").map(x => x.getInt * 1000).get(0)
                let time = (json["date"].getInt * 1000).int64
                let message = json.opt("text").map(x => x.getStr(nil)).get(nil)

                db.exec(("INSERT INTO log (id, target_id, from_id, from_name, from_username, " &
                  "to_id, to_name, to_username, reply_id, " &
                  "forward_id, forward_name, forward_username, forward_time, " &
                  "time, message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").sql,
                  id, targetId, fromId, fromName, fromUsername, toId, toName, toUsername,
                  replyId, forwardId, forwardName, forwardUsername, forwardTime, time, message)
            except:
              let msg = getCurrentExceptionMsg()
              if msg != "UNIQUE constraint failed: log.id":
                echo(msg)

          linebuf.setLen(0)
          break
      linebuf &= readbuf[fromIndex .. count - 1]

    db.close()

    var rescode: cint
    discard waitpid(pid, rescode, 0)
    programResult = 0
elif params.len >= 2 and params[0] == "id":
  let peer = params[1].peer
  echo("Peer type ", peer.peerType)
  echo("Peer ID ", peer.peerId)
  echo("Chat ID ", peer.id)
  echo("Access hash ", peer.accessHash)
elif params.len >= 1 and params[0] == "chats":
  let db = open("log.sqlite", "", "", "")
  var rows: seq[tuple[id: string, name: string]] = @[]

  for row in db.rows(("SELECT DISTINCT target_id, from_name FROM log " &
    "WHERE target_id == from_id").sql):
    if row[1] != nil and row[1].len > 0:
      rows &= (row[0], row[1])

  for row in db.rows(("SELECT DISTINCT target_id, to_name FROM log " &
    "WHERE target_id == to_id").sql):
    if row[1] != nil and row[1].len > 0:
      rows &= (row[0], row[1])

  let chats = rows.deduplicate
  let targets = chats.map(x => x.id).deduplicate
  let groups: seq[tuple[id: string, chats: seq[string]]] = targets
    .map(x => (x, chats.filter(y => y.id == x).map(x => x.name)))

  let filterChat = if params.len >= 2: params[1] else: ""

  for group in groups:
    if group.chats.filter(x => x.contains(filterChat)).len > 0:
      echo(group.id, " :: ", group.chats.map(x => "\"" & x & "\"").foldl(a & ", " & b))

  db.close()
  programResult = 0
elif params.len >= 1 and params[0] == "query":
  let db = open("log.sqlite", "", "", "")

  const dateFormat = "yyyy-MM-dd HH:mm:ss"

  let columns = if params.len >= 3 and params[1] == "last": (block:
      let count = params[2].parseBiggestInt.int
      if params.len >= 4:
        db.getAllRows("SELECT * FROM log WHERE target_id == ? ORDER BY time DESC LIMIT ?".sql,
          params[3].parseBiggestInt.int64, count).reversed
      else:
        db.getAllRows("SELECT * FROM log ORDER BY time DESC LIMIT ?".sql, count).reversed)
    elif params.len >= 3 and params[1] == "from": (block:
      let time = try:
        params[2].parseBiggestInt.int64
      except ValueError:
        params[2].parse(dateFormat).toTime.toUnix * 1000
      let limit = if params.len >= 4: params[3].parseBiggestInt.int else: int.high
      db.getAllRows("SELECT * FROM log WHERE time >= ? ORDER BY time LIMIT ?".sql, time, limit))
    elif params.len >= 3 and params[1] == "search": (block:
      let limit = if params.len >= 4: params[3].parseBiggestInt.int else: int.high
      db.getAllRows("SELECT * FROM log WHERE message LIKE ? ORDER BY time DESC LIMIT ?".sql,
        params[2], limit)).reversed
    else:
      @[]

  type Message = object
    id: string
    targetId: int64
    fromId: int64
    fromName: string
    fromUsername: Option[string]
    toId: int64
    toName: string
    toUsername: Option[string]
    replyId: Option[string]
    forwardId: Option[int64]
    forwardName: Option[string]
    forwardUsername: Option[string]
    forwardTime: Option[int64]
    time: int64
    message: Option[string]

  proc message(row: seq[string]): Message =
    template opt(s: string): Option[string] =
      if s == nil or s.len == 0: none(string) else: some(s)

    let id = row[0]
    let targetId = row[1].parseBiggestInt.int64
    let fromId = row[2].parseBiggestInt.int64
    let fromName = row[3]
    let fromUsername = row[4].nilIfEmpty.opt
    let toId = row[5].parseBiggestInt.int64
    let toName = row[6]
    let toUsername = row[7].nilIfEmpty.opt
    let replyId = row[8].nilIfEmpty.opt
    let forwardId = some(row[9].parseBiggestInt.int64)
      .map(x => (if x == 0: none(int64) else: some(x))).flatten
    let forwardName = row[10].nilIfEmpty.opt
    let forwardUsername = row[11].nilIfEmpty.opt
    let forwardTime = some(row[12].parseBiggestInt.int64)
      .map(x => (if x == 0: none(int64) else: some(x))).flatten
    let time = row[13].parseBiggestInt.int64
    let message = row[14].nilIfEmpty.opt

    Message(id: id, targetId: targetId,
      fromId: fromId, fromName: fromName, fromUsername: fromUsername,
      toId: toId, toName: toName, toUsername: toUsername,
      replyId: replyId, forwardId: forwardId, forwardName: forwardName,
      forwardUsername: forwardUsername, forwardTime: forwardTime,
      time: time, message: message)

  let messages = columns.map(message)
  let messagesById = messages.map(m => (m.id, m)).toTable

  let queryReplies = messages
    .map(m => m.replyId)
    .filter(i => i.isSome)
    .map(i => i.unsafeGet)
    .filter(i => not messagesById.hasKey(i))

  let queryResults = if queryReplies.len > 0: (block:
      let arr = "(" & queryReplies.filter(x => not ("'" in x))
        .map(x => "'" & x & "'").foldl(a & ", " & b) & ")"
      let rows = db.getAllRows(("SELECT * FROM log WHERE id IN " & arr).sql)
      rows.map(message))
    else:
      @[]

  let allMessagesById = (queryResults & messages).map(m => (m.id, m)).toTable
  let multipleChats = messages.map(m => m.targetId).deduplicate.len >= 2

  proc formatTime(time: int64): string =
    fromUnix(time /% 1000).local.format(dateFormat)

  proc formatName(name: string, username: Option[string]): string =
    username.map(un => name & " @" & un).get(name)

  proc formatTitle(message: Message, color: bool): string =
    let forwardHeader = if message.forwardTime.isSome:
        (if color: ^Color.blue else: "") &
          "Forwarded [" & formatTime(message.forwardTime.unsafeGet) & "] " &
          formatName(message.forwardName.get, message.forwardUsername) &
          (if color: ^Color.normal else: "") & "\n"
      else:
        ""

    let targetName = if message.targetId == message.fromId:
        message.fromName
      else:
        message.toName

    forwardHeader & "[" & formatTime(message.time) & "] " &
      formatName(message.fromName, message.fromUsername) &
      (if multipleChats: " (" & targetName & ")" else: "") & ": "

  proc formatMessageText(message: Message, color: bool): string =
    if message.message.isNone:
      (if color: ^Color.red else: "") &
        "photo, sticker or document" &
        (if color: ^Color.normal else: "")
    else:
      message.message.unsafeGet

  for message in messages:
    if message.replyId.isSome:
      let replyId = message.replyId.unsafeGet
      if allMessagesById.hasKey(replyId):
        let replyMessage = allMessagesById[replyId]
        echo(^Color.green, "> ", (formatTitle(replyMessage, false) &
          formatMessageText(replyMessage, false)).replace("\n", "\n> "), ^Color.normal)
      else:
        echo(^Color.red, "> Failed to extract replied message", ^Color.normal)
    echo(formatTitle(message, true), formatMessageText(message, true))

  db.close()
  programResult = if columns.len > 0: 0 else: 1
elif params.len >= 1 and params[0] == "convert-v1":
  convert("""CREATE TABLE IF NOT EXISTS log (
      id TEXT PRIMARY KEY NOT NULL,
      target_id LONG NOT NULL,
      from_id LONG NOT NULL,
      from_name LONG NOT NULL,
      from_username TEXT,
      to_id TEXT NOT NULL,
      to_name TEXT NOT NULL,
      to_username TEXT,
      reply_id TEXT,
      time LONG NOT NULL,
      message TEXT
    )""", proc (db: DbConn, row: seq[string]) =
    let idPeer = row[0].peer
    let id = idPeer.accessHash
    let targetId = idPeer.id
    let fromId = row[1].peer.id
    let fromName = row[2]
    let fromUsername: string = nil
    let toId = row[3].peer.id
    let toName = row[4]
    let toUsername: string = nil
    let replyId = some(row[5])
      .map(x => (if x.len > 0: some(x) else: none(string))).flatten
      .map(x => x.peer.accessHash).get(nil)
    let time = row[6].parseBiggestInt.int64
    let message = some(row[7])
      .map(x => (if x == "NO TEXT" or x.len == 0: none(string) else: some(x))).flatten
      .get(nil)

    db.exec(("INSERT INTO log (id, target_id, from_id, from_name, from_username, " &
      "to_id, to_name, to_username, reply_id, time, message) " &
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").sql,
      id, targetId, fromId, fromName, fromUsername,
      toId, toName, toUsername, replyId, time, message))

  programResult = 0
elif params.len >= 1 and params[0] == "convert-v2":
  convert("""CREATE TABLE IF NOT EXISTS log (
      id TEXT PRIMARY KEY NOT NULL,
      target_id LONG NOT NULL,
      from_id LONG NOT NULL,
      from_name TEXT NOT NULL,
      from_username TEXT,
      to_id LONG NOT NULL,
      to_name TEXT NOT NULL,
      to_username TEXT,
      reply_id TEXT,
      forward_id LONG NOT NULL,
      forward_name TEXT,
      forward_username TEXT,
      forward_time LONG NOT NULL,
      time LONG NOT NULL,
      message TEXT
    )""", proc (db: DbConn, row: seq[string]) =
    let id = row[0]
    let targetId = row[1].parseBiggestInt.int64
    let fromId = row[2].parseBiggestInt.int64
    let fromName = row[3]
    let fromUsername = row[4].nilIfEmpty
    let toId = row[5].parseBiggestInt.int64
    let toName = row[6]
    let toUsername = row[7].nilIfEmpty
    let replyId = row[8].nilIfEmpty
    let forwardId = 0
    let forwardName: string = nil
    let forwardUsername: string = nil
    let forwardTime = 0
    let time = row[9].parseBiggestInt.int64
    let message = row[10].nilIfEmpty

    db.exec(("INSERT INTO log (id, target_id, from_id, from_name, from_username, " &
      "to_id, to_name, to_username, reply_id, " &
      "forward_id, forward_name, forward_username, forward_time, " &
      "time, message) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").sql,
      id, targetId, fromId, fromName, fromUsername, toId, toName, toUsername,
      replyId, forwardId, forwardName, forwardUsername, forwardTime, time, message))

  programResult = 0
else:
  echo("Invalid arguments")
  programResult = 1
