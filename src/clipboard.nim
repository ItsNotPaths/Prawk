## Clipboard shell-out via xclip. No xclip → silent no-op.
##
## X11 has two independent selections:
##   CLIPBOARD — the explicit-copy buffer (Ctrl+C / Ctrl+V).
##   PRIMARY   — the just-selected buffer (highlight → middle-click paste).
## Native apps write to both: PRIMARY on selection finalize, CLIPBOARD on
## explicit copy. We mirror that contract.

import std/[osproc, streams]

proc clipboardGet*(): string =
  ## Reads CLIPBOARD selection. xclip emits raw bytes (no trailing \n),
  ## which is what we want when piping into PTYs / palette buffers.
  try:
    let p = startProcess("xclip", args = ["-selection", "clipboard", "-o"],
                        options = {poUsePath})
    # waitForExit reaps but doesn't release the pipe FDs — without close() we
    # leak per call and eventually EMFILE makes paste/copy silently no-op.
    defer: p.close()
    result = p.outputStream.readAll()
    discard p.waitForExit()
  except CatchableError:
    discard

proc writeSelection(sel: string, s: string) =
  try:
    let p = startProcess("xclip", args = ["-selection", sel, "-i"],
                        options = {poUsePath})
    defer: p.close()
    p.inputStream.write(s)
    p.inputStream.close()
    discard p.waitForExit()
  except CatchableError:
    discard

proc clipboardSet*(s: string) =
  ## Explicit-copy target (Ctrl+C / Ctrl+Shift+C path).
  writeSelection("clipboard", s)

proc clipboardSetPrimary*(s: string) =
  ## Selection-finalize target (mouse-up / shift+arrow). Middle-click pastes.
  writeSelection("primary", s)

proc clipboardSetBoth*(s: string) =
  clipboardSet(s)
  clipboardSetPrimary(s)
