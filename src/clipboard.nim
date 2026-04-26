## Clipboard shell-out via xclip. No xclip → silent no-op (the user simply
## doesn't get paste; copy is a stub for now anyway).

import std/[osproc, streams]

proc clipboardGet*(): string =
  ## Reads CLIPBOARD selection. xclip emits raw bytes (no trailing \n),
  ## which is what we want when piping into PTYs / palette buffers.
  try:
    let p = startProcess("xclip", args = ["-selection", "clipboard", "-o"],
                        options = {poUsePath})
    result = p.outputStream.readAll()
    discard p.waitForExit()
  except CatchableError:
    discard

proc clipboardSet*(s: string) =
  ## Wired but unused until we ship terminal/editor selection. Kept here
  ## so the eventual copy bindings can call into a single place.
  try:
    let p = startProcess("xclip", args = ["-selection", "clipboard", "-i"],
                        options = {poUsePath})
    p.inputStream.write(s)
    p.inputStream.close()
    discard p.waitForExit()
  except CatchableError:
    discard
