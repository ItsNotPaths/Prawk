import std/os
import posix

{.passL: "-lutil".}

type WinSize {.importc: "struct winsize", header: "<sys/ioctl.h>", bycopy.} = object
  ws_row: cushort
  ws_col: cushort
  ws_xpixel: cushort
  ws_ypixel: cushort

proc forkpty(master: ptr cint, name: ptr char, tp: pointer, ws: ptr WinSize): Pid
  {.importc, header: "<pty.h>".}

const TIOCSWINSZ = 0x5414
proc ioctl(fd: cint, req: culong): cint {.importc, varargs, header: "<sys/ioctl.h>", discardable.}

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc startShell*(rows, cols: int, workDir: string = ""): tuple[fd: cint, pid: Pid] =
  var ws = WinSize(ws_row: rows.cushort, ws_col: cols.cushort)
  var fd: cint = -1
  let pid = forkpty(addr fd, nil, nil, addr ws)
  if pid < 0:
    return (cint(-1), Pid(-1))
  if pid == 0:
    # child: exec $SHELL
    if workDir.len > 0:
      discard chdir(workDir.cstring)
    let shell = getEnv("SHELL", "/bin/sh")
    putEnv("TERM", "ansi")
    var argv = allocCStringArray([shell, "-i"])
    discard execvp(shell.cstring, argv)
    quit(1)
  setNonBlocking(fd)
  return (fd, pid)

proc resize*(fd: cint, rows, cols: int) =
  var ws = WinSize(ws_row: rows.cushort, ws_col: cols.cushort)
  discard ioctl(fd, TIOCSWINSZ.culong, addr ws)
