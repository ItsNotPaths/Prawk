import std/[os, strutils, sequtils]

type
  TabMode* = enum tmSpaces2, tmSpaces4, tmTab
  FocusTarget* = enum ftTree, ftEditor, ftTerm

var
  tabMode*: TabMode = tmSpaces4
  initialFocus*: FocusTarget = ftTerm
  initialTermIdx*: int = 0
  initialTerminals*: int = 2

proc indentString*(): string =
  case tabMode
  of tmSpaces2: "  "
  of tmSpaces4: "    "
  of tmTab:     "\t"

proc configDir*(): string = getConfigDir() / "prawk"

proc loadConfig*() =
  let path = configDir() / "config"
  if not fileExists(path): return
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip()
    let val = line[colon+1 .. ^1].strip()
    case key
    of "tab_mode":
      case val
      of "spaces2": tabMode = tmSpaces2
      of "spaces4": tabMode = tmSpaces4
      of "tab":     tabMode = tmTab
      else: discard
    of "initial_focus":
      case val
      of "tree":     initialFocus = ftTree
      of "editor":   initialFocus = ftEditor
      of "terminal": initialFocus = ftTerm
      else: discard
    of "initial_term":
      try: initialTermIdx = parseInt(val)
      except ValueError: discard
    of "initial_terminals":
      try:
        let n = parseInt(val)
        if n >= 1: initialTerminals = n
      except ValueError: discard
    else: discard

proc readRecents*(name: string): seq[string] =
  result = @[]
  let path = configDir() / name
  if not fileExists(path): return
  for raw in lines(path):
    let s = raw.strip()
    if s.len > 0: result.add(s)

proc writeRecents*(name: string, paths: seq[string]) =
  try:
    createDir(configDir())
    let path = configDir() / name
    var buf = ""
    for p in paths: buf.add(p & "\n")
    writeFile(path, buf)
  except IOError, OSError:
    discard

proc pushRecent*(name, path: string) =
  if path.len == 0: return
  let abs = absolutePath(path)
  var list = readRecents(name)
  list.keepItIf(it != abs)
  list.insert(abs, 0)
  if list.len > 10: list.setLen(10)
  writeRecents(name, list)

proc readSession*(): seq[string] =
  ## One line per terminal — empty lines mean "no user-set name" (default).
  ## Order matches the saved stack, so the count is the line count.
  result = @[]
  let path = configDir() / "session"
  if not fileExists(path): return
  for raw in lines(path):
    result.add(raw.strip())

proc writeSession*(names: seq[string]) =
  try:
    createDir(configDir())
    let path = configDir() / "session"
    var buf = ""
    for n in names: buf.add(n & "\n")
    writeFile(path, buf)
  except IOError, OSError:
    discard
