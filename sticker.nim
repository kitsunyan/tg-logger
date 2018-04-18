import future, posix, sequtils, strutils

proc escape(r: int, g: int, b: int, a: int): string =
  if a >= 127:
    template `@`(x: int): int = (x / 256 * 25).int
    template `^`(x: int): int = (x / 256 * 6).int

    let index = if @r < 24 and @r == @g and @g == @b:
        231 + @r
      else:
        ^r * 6 * 6 + ^g * 6 + ^b + 16

    "\x1b[48;5;" & $index & "m"
  else:
    "\x1b[0m"

proc convertStickerBytes(file: string, size: int): (int, int, seq[cchar]) =
  var fd: array[2, cint]
  discard pipe(fd)

  let pid = fork()
  if pid == 0:
    discard close(fd[0])
    discard close(1)
    discard dup(fd[1])
    discard close(fd[1])

    discard close(0)
    let code = if open(file, O_RDONLY) == 0: (block:
        let args = ["convert", "-", "-resize", $size & "x" & $size,
          "-depth", "8", "-print", "%w %h ", "rgba:-"]
        let cexec = allocCStringArray(args)
        execvp(cexec[0], cexec))
      else:
        1
    quit(code)
  else:
    discard close(fd[1])
    var linebuf: seq[cchar] = @[]
    var readbuf: array[80, cchar]

    proc readDimension(): int =
      result = 0
      for i in 0 .. readbuf.high:
        if read(fd[0], addr(readbuf[i]), 1) != 1:
          break
        elif readbuf[i] == ' ':
          readbuf[i] = '\0'
          let s: cstring = addr(readbuf[0])
          result = ($s).parseInt
          break

    let width = readDimension()
    let height = readDimension()

    while true:
      let count = read(fd[0], addr(readbuf[0]), readbuf.len)
      if count > 0:
        linebuf &= readbuf[0 .. count - 1]
      else:
        break

    var rescode: cint
    discard waitpid(pid, rescode, 0)
    if rescode == 0:
      (width, height, linebuf)
    else:
      (0, 0, @[])

proc convertSticker*(file: string, size: int): seq[seq[string]] =
  let (width, height, bytes) = convertStickerBytes(file, size)

  if width > 0 and height > 0 and 4 * width * height == bytes.len:
    bytes.distribute(height).map(s => s.distribute(width)
      .map(c => escape(c[0].int and 0xff, c[1].int and 0xff,
        c[2].int and 0xff, c[3].int and 0xff)))
  else:
    @[]
