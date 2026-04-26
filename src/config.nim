import std/[os, strutils]

type
  TabMode* = enum tmSpaces2, tmSpaces4, tmTab
  FocusTarget* = enum ftTree, ftEditor, ftTerm
  LineNumberMode* = enum lnmOff, lnmGlobal, lnmRelative
  CursorMode* = enum cmInsert, cmNormal
  TerminalCopyPaste* = enum tcpIde, tcpLegacy

var
  tabMode*: TabMode = tmSpaces4
  initialFocus*: FocusTarget = ftTree
  initialTermIdx*: int = 0
  initialTerminals*: int = 2
  grepIgnore*: seq[string] = @[]
  themePref*: string = "default"
  cursorJumpLines*: int = 10
  lineNumbers*: LineNumberMode = lnmGlobal
  cursorMode*: CursorMode = cmInsert
  clearOnProjectCd*: bool = false
  terminalCopyPaste*: TerminalCopyPaste = tcpIde

proc tildify*(p: string): string =
  let h = getHomeDir()
  if h.len > 0 and p.startsWith(h):
    "~/" & p[h.len .. ^1]
  else:
    p

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
    of "grep_ignore":
      grepIgnore = @[]
      for raw in val.split(','):
        let s = raw.strip()
        if s.len > 0: grepIgnore.add(s)
    of "theme":
      if val.len > 0: themePref = val
    of "cursor_jump_lines":
      try:
        let n = parseInt(val)
        if n >= 1: cursorJumpLines = n
      except ValueError: discard
    of "line_numbers":
      case val
      of "off":      lineNumbers = lnmOff
      of "global":   lineNumbers = lnmGlobal
      of "relative": lineNumbers = lnmRelative
      else: discard
    of "cursor_mode":
      case val
      of "insert": cursorMode = cmInsert
      of "normal": cursorMode = cmNormal
      else: discard
    of "clear_on_project_cd":
      case val
      of "true", "yes", "on", "1":  clearOnProjectCd = true
      of "false", "no", "off", "0": clearOnProjectCd = false
      else: discard
    of "terminal_copy_paste":
      case val
      of "ide":    terminalCopyPaste = tcpIde
      of "legacy": terminalCopyPaste = tcpLegacy
      else: discard
    else: discard

proc setConfigKey*(key, val: string) =
  ## Reads ~/.config/prawk/config, replaces or appends `key: val`, writes
  ## atomically (temp + moveFile). Preserves other lines and comments.
  try:
    createDir(configDir())
    let path = configDir() / "config"
    var entries: seq[string] = @[]
    if fileExists(path):
      for raw in lines(path): entries.add(raw)
    var replaced = false
    for i in 0 ..< entries.len:
      let s = entries[i].strip()
      if s.len == 0 or s.startsWith('#'): continue
      let colon = s.find(':')
      if colon <= 0: continue
      let k = s[0 ..< colon].strip()
      if k == key:
        entries[i] = key & ": " & val
        replaced = true
        break
    if not replaced:
      entries.add(key & ": " & val)
    var buf = ""
    for ln in entries: buf.add(ln & "\n")
    let tmp = path & ".prawk-tmp"
    writeFile(tmp, buf)
    moveFile(tmp, path)
  except IOError, OSError:
    discard

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
  var kept: seq[string]
  for it in list:
    if it != abs: kept.add(it)
  list = kept
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
