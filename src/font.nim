import std/[os, osproc, strutils]
import luigi

const defaultSize* = 14

proc systemMonoPath(): string =
  let override = getEnv("PRAWK_FONT")
  if override.len > 0 and fileExists(override):
    return override
  try:
    let (output, code) = execCmdEx("fc-match --format=%{file} monospace:mono")
    if code == 0:
      let p = output.strip()
      if p.len > 0 and fileExists(p):
        return p
  except CatchableError:
    discard
  return ""

proc glyphDims*(): (cint, cint) =
  if ui.activeFont != nil:
    (ui.activeFont.glyphWidth, ui.activeFont.glyphHeight)
  else:
    (9.cint, 16.cint)

proc loadFont*(size: uint32 = defaultSize) =
  let path = systemMonoPath()
  if path.len == 0: return
  let f = fontCreate(path.cstring, size)
  if f != nil:
    discard fontActivate(f)
