import future, posix, sequtils, strutils

type Pixel = tuple[r: int, g: int, b: int, a: int]

proc escape256(r: int, g: int, b: int, a: int): int =
  if a >= 127:
    template `@`(x: int): int = (x / 256 * 25).int
    template `^`(x: int): int = (x / 256 * 6).int

    let index = if @r < 24 and @r == @g and @g == @b:
        231 + @r
      else:
        ^r * 6 * 6 + ^g * 6 + ^b + 16

    index
  else:
    0

template formatPair(trueColor: bool, p0: Pixel, p1: Pixel): string =
  if trueColor:
    if p0.a < 127 and p1.a < 127:
      "\x1b[0m "
    elif p0.a >= 127 and p1.a < 127:
      "\x1b[0;38;2;" & $p0.r & ";" & $p0.g & ";" & $p0.b & "m\xe2\x96\x80"
    elif p0.a < 127 and p1.a >= 127:
      "\x1b[0;38;2;" & $p1.r & ";" & $p1.g & ";" & $p1.b & "m\xe2\x96\x84"
    else:
      "\x1b[38;2;" & $p0.r & ";" & $p0.g & ";" & $p0.b & ";" &
        "48;2;" & $p1.r & ";" & $p1.g & ";" & $p1.b & "m\xe2\x96\x80"
  else:
    let p0v = escape256(p0.r, p0.g, p0.b, p0.a)
    let p1v = escape256(p1.r, p1.g, p1.b, p1.a)

    if p0v == 0 and p1v == 0:
      "\x1b[0m "
    elif p0v != 0 and p1v == 0:
      "\x1b[0;38;5;" & $p0v & "m\xe2\x96\x80"
    elif p0v == 0 and p1v != 0:
      "\x1b[0;38;5;" & $p1v & "m\xe2\x96\x84"
    else:
      "\x1b[38;5;" & $p0v & ";48;5;" & $p1v & "m\xe2\x96\x80"

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

proc convertStickerPixels(file: string, size: int): seq[seq[Pixel]] =
  let (width, height, bytes) = convertStickerBytes(file, size)

  if width > 0 and height > 0 and 4 * width * height == bytes.len:
    bytes.distribute(height).map(s => s.distribute(width)
      .map(c => (c[0].int and 0xff, c[1].int and 0xff,
        c[2].int and 0xff, c[3].int and 0xff)))
  else:
    @[]

proc even(pixels: seq[seq[Pixel]]): seq[seq[Pixel]] =
  let even = pixels.map(line =>
    (if line.len %% 2 == 1: line & @[(0, 0, 0, 0)] else: line))

  if even.len %% 2 == 1:
    even & (0, 0, 0, 0).repeat(even[0].len)
  else:
    even

proc convertSticker*(file: string, size: int, trueColor: bool): seq[string] =
  let pixels = convertStickerPixels(file, 2 * size).even
  result = @[]

  for y in 0 .. (pixels.len /% 2) - 1:
    let y0l = pixels[2 * y]
    let y1l = pixels[2 * y + 1]

    result &= y0l.zip(y1l)
      .map(pair => (block:
        let (i0, i1) = pair
        formatPair(trueColor, i0, i1)))
      .foldl(a & b)
