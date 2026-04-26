import std/[os, strutils]
import posix, posix/termios
import luigi, commands, resultspane, project, pty, config

proc atexit(p: proc() {.cdecl.}): cint {.importc, header: "<stdlib.h>", discardable.}
proc clock_gettime(clkId: cint, tp: ptr Timespec): cint
  {.importc, header: "<time.h>", discardable.}
const CLOCK_MONOTONIC = 1.cint

proc monoNs(): int64 =
  var ts: Timespec
  clock_gettime(CLOCK_MONOTONIC, addr ts)
  int64(ts.tv_sec) * 1_000_000_000 + int64(ts.tv_nsec)

proc clLog(msg: string) =
  try: stderr.writeLine("[cl] " & msg); stderr.flushFile()
  except IOError: discard

type
  GrepHit* = object
    file*: string
    line*, col*: int
    text*: string

  GrepResults* = object
    hits*: seq[GrepHit]
    lastQuery*: string

  ShellRun* = object
    lines*: seq[string]
    label*: string

  ClRun = enum crIdle, crShell, crGrep

  ClShell = object
    fd: cint
    pid: Pid
    sentinel: string
    readBuf: array[4096, char]
    lineBuf: string
    ringBuf: seq[string]
    ringHead: int       # index of oldest line in ringBuf
    pendingHits: seq[GrepHit]
    state: ClRun

const
  ringCap = 500
  clRows = 40
  clCols = 200

var
  theClShell: ClShell
  theGrepState*: GrepResults
  theShellState*: ShellRun
  theClPane: ptr ResultsPane

# ---------- low-level i/o ----------

proc clShellWrite*(line: string) =
  if theClShell.fd < 0 or line.len == 0:
    clLog("write skipped: fd=" & $theClShell.fd & " len=" & $line.len)
    return
  var payload = line & "\n\n"
  if theClShell.sentinel.len > 0:
    payload.add(theClShell.sentinel & "\n")
  let nw = write(theClShell.fd, payload.cstring, payload.len)
  clLog("write: " & line & " (" & $nw & "/" & $payload.len & " bytes)")

proc onProjectChange() =
  if theClShell.fd >= 0 and project.projectRoot.len > 0:
    clShellWrite("cd " & quoteShell(project.projectRoot))

proc shutdown() {.cdecl.} =
  if theClShell.pid > 0:
    discard kill(theClShell.pid, SIGTERM)
  if theClShell.fd >= 0:
    discard close(theClShell.fd)
    theClShell.fd = -1

proc generateSentinel(): string =
  let seed = cast[uint64](monoNs()) xor cast[uint64](getpid())
  let hex = toHex(int64(seed and 0xFFFFFFFF'u64), 8).toLowerAscii
  "__prawk_sentinel_" & hex

proc clShellInit*(workDir: string) =
  theClShell.fd = -1
  theClShell.pid = Pid(-1)
  theClShell.lineBuf = ""
  theClShell.ringBuf = @[]
  theClShell.pendingHits = @[]
  theClShell.state = crIdle
  theClShell.sentinel = generateSentinel()
  let (fd, pid) = startShell(clRows, clCols, workDir, "dumb")
  clLog("init: workDir=" & workDir & " fd=" & $fd & " pid=" & $pid &
        " sentinel=" & theClShell.sentinel)
  if fd < 0: return
  theClShell.fd = fd
  theClShell.pid = pid
  pty.resize(fd, clRows, clCols)
  # Disable TTY echo so the master fd doesn't see typed input bouncing
  # back — otherwise the sentinel substring lands in our line stream
  # before the user's command has had a chance to run.
  var ts: Termios
  if tcgetattr(fd, addr ts) == 0:
    ts.c_lflag = ts.c_lflag and not Cflag(ECHO or ECHOE or ECHOK or ECHONL)
    discard tcsetattr(fd, TCSANOW, addr ts)
  project.registerProjectChange(onProjectChange)
  atexit(shutdown)
  # prime the matcher with an initial sentinel so the first user run
  # has a clean boundary.
  let prime = theClShell.sentinel & "\n"
  discard write(theClShell.fd, prime.cstring, prime.len)

# ---------- escape stripping ----------

proc stripCsi(s: string): string =
  ## TERM=dumb; only handle CSI (`ESC [ ... <final>`), backspace, and CR.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\x1b' and i + 1 < s.len and s[i+1] == '[':
      i += 2
      while i < s.len:
        let b = byte(s[i])
        inc i
        if b >= 0x40'u8 and b <= 0x7e'u8: break
    elif c == '\x08':
      if result.len > 0: result.setLen(result.len - 1)
      inc i
    elif c == '\r':
      inc i
    else:
      result.add c
      inc i

# ---------- matcher ----------

proc tryParseHit(line: string): (bool, GrepHit) =
  result = (false, GrepHit())
  if line.len == 0: return
  if line[0] in {' ', '\t', ':'}: return
  # Pick the FIRST `:` whose left side contains a `/` or `.`. On Linux the
  # path can itself contain spaces but cannot contain `:`, so the path token
  # ends at the first `:`. Drive letters (`C:` on Windows) aren't a concern
  # since prawk is Linux-only at this pass.
  let firstColon = line.find(':')
  if firstColon <= 0 or firstColon >= line.len - 1: return
  let path = line[0 ..< firstColon]
  var looksLikeFile = false
  for ch in path:
    if ch == '/' or ch == '.':
      looksLikeFile = true; break
  if not looksLikeFile: return

  var i = firstColon + 1
  let lineStart = i
  while i < line.len and line[i] in {'0' .. '9'}: inc i
  if i == lineStart: return
  var lineNum = 0
  try: lineNum = parseInt(line[lineStart ..< i])
  except ValueError: return
  if i >= line.len or line[i] != ':': return

  var colNum = 0
  if i + 1 < line.len and line[i+1] in {'0' .. '9'}:
    inc i  # consume first ':'
    let colStart = i
    while i < line.len and line[i] in {'0' .. '9'}: inc i
    try: colNum = parseInt(line[colStart ..< i])
    except ValueError: return
    if i >= line.len or line[i] != ':': return

  inc i  # consume the ':' before text
  var textStart = i
  while textStart < line.len and line[textStart] in {' ', '\t'}:
    inc textStart
  let text = if textStart < line.len: line[textStart .. ^1] else: ""

  var abs = path
  if not isAbsolute(abs) and project.projectRoot.len > 0:
    abs = project.projectRoot / abs
  result = (true, GrepHit(file: abs, line: lineNum, col: colNum, text: text))

# ---------- grep provider ----------

proc grepHeader(abs: string, full: bool): string =
  ## Grep row title. `full` (Shift held) → root-relative or `~/...` path.
  ## Otherwise → bare filename if at project root, `.../filename` deeper.
  if full:
    let root = project.projectRoot
    if root.len > 0 and abs.startsWith(root & "/"):
      return abs[root.len + 1 .. ^1]
    return config.tildify(abs)
  let fname = extractFilename(abs)
  if project.projectRoot.len > 0 and parentDir(abs) == project.projectRoot:
    return fname
  ".../" & fname

var theShiftHeld*: bool

proc grepRowCount(s: pointer): int {.nimcall.} =
  let g = cast[ptr GrepResults](s)
  if g.hits.len == 0: 1
  else: g.hits.len * 2

proc grepRowText(s: pointer, i: int): string {.nimcall.} =
  ## Used as a fallback by the default painter; the custom painter below
  ## is what actually runs.
  let g = cast[ptr GrepResults](s)
  if g.hits.len == 0:
    return "(no matches for " & g.lastQuery & ")"
  let hitIdx = i div 2
  if hitIdx < 0 or hitIdx >= g.hits.len: return ""
  if (i mod 2) == 0:
    let h = g.hits[hitIdx]
    let name = grepHeader(h.file, theShiftHeld)
    name & ":" & $h.line
  else:
    "  " & g.hits[hitIdx].text

proc grepPaintRow(s: pointer, i: int, p: ptr Painter, r: Rectangle, sel: bool) {.nimcall.} =
  let g = cast[ptr GrepResults](s)
  if g.hits.len == 0:
    let bg = if sel: ui.theme.selected else: ui.theme.panel1
    drawBlock(p, r, bg)
    let txt = "(no matches for " & g.lastQuery & ")"
    drawString(p, r, txt.cstring, txt.len, ui.theme.text,
               cint(ALIGN_LEFT), nil)
    return
  let hitIdx = i div 2
  let isSnippet = (i mod 2) == 1
  if hitIdx < 0 or hitIdx >= g.hits.len:
    drawBlock(p, r, ui.theme.panel1)
    return
  # Both rows of a hit share the same selection highlight — driven by the
  # pane's selected index, paired with this row's hit.
  let selectedHitIdx =
    if theClPane != nil: theClPane.selected div 2 else: -1
  let pairSel = (hitIdx == selectedHitIdx)
  let bg = if pairSel: ui.theme.selected else: ui.theme.panel1
  drawBlock(p, r, bg)
  let h = g.hits[hitIdx]
  if not isSnippet:
    let name = grepHeader(h.file, theShiftHeld)
    let label = name & ":" & $h.line
    let color = if pairSel: ui.theme.textSelected else: ui.theme.text
    drawString(p, r, label.cstring, label.len, color,
               cint(ALIGN_LEFT), nil)
  else:
    let snippet = "    " & h.text
    let color =
      if pairSel: ui.theme.textSelected
      else: 0x7c6b9e'u32  # gruvbox muted, gives the snippet a softer tier
    drawString(p, r, snippet.cstring, snippet.len, color,
               cint(ALIGN_LEFT), nil)

proc grepOnSelect(s: pointer, i: int) {.nimcall.} =
  let g = cast[ptr GrepResults](s)
  if g.hits.len == 0: return
  let hitIdx = i div 2
  if hitIdx < 0 or hitIdx >= g.hits.len: return
  discard runCommand("editor.open", @[g.hits[hitIdx].file])

proc grepOnKey(s: pointer, code: cint, ctrl, shift: bool): bool {.nimcall.} =
  if theClPane == nil: return false
  let g = cast[ptr GrepResults](s)
  if g.hits.len == 0: return false
  let total = g.hits.len * 2
  # Selection is anchored to the header row of a hit (always even); j/k
  # step a full pair so the user moves one hit at a time.
  if theClPane.selected mod 2 != 0:
    theClPane.selected = max(0, theClPane.selected - 1)
  if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
    if theClPane.selected + 2 < total:
      theClPane.selected += 2
    return true
  if code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
    if theClPane.selected >= 2:
      theClPane.selected -= 2
    return true
  false

proc grepProvider(): Provider =
  Provider(
    state: cast[pointer](addr theGrepState),
    name: "grep",
    rowCount: grepRowCount,
    rowText: grepRowText,
    onPaintRow: grepPaintRow,
    onSelect: grepOnSelect,
    onContext: nil,
    onKey: grepOnKey,
    onBack: nil)

# ---------- shell provider (raw output of fall-through commands) ----------

proc shellRowCount(s: pointer): int {.nimcall.} =
  let st = cast[ptr ShellRun](s)
  if st.lines.len == 0: 1
  else: st.lines.len

proc shellRowText(s: pointer, i: int): string {.nimcall.} =
  let st = cast[ptr ShellRun](s)
  if st.lines.len == 0:
    return "(no output for " & st.label & ")"
  if i < 0 or i >= st.lines.len: return ""
  st.lines[i]

proc shellOnSelect(s: pointer, i: int) {.nimcall.} =
  let st = cast[ptr ShellRun](s)
  if st.lines.len == 0: return
  if i < 0 or i >= st.lines.len: return
  let (ok, hit) = tryParseHit(st.lines[i])
  if ok:
    discard runCommand("editor.open", @[hit.file])

proc shellProvider(): Provider =
  Provider(
    state: cast[pointer](addr theShellState),
    name: "shell",
    rowCount: shellRowCount,
    rowText: shellRowText,
    onPaintRow: nil,
    onSelect: shellOnSelect,
    onContext: nil,
    onKey: nil,
    onBack: nil)

# ---------- :cl provider ----------

proc clRowCount(s: pointer): int {.nimcall.} =
  cast[ptr ClShell](s).ringBuf.len

proc ringAt(cs: ptr ClShell, i: int): string =
  if cs.ringBuf.len < ringCap: cs.ringBuf[i]
  else: cs.ringBuf[(cs.ringHead + i) mod ringCap]

proc clRowText(s: pointer, i: int): string {.nimcall.} =
  let cs = cast[ptr ClShell](s)
  if i < 0 or i >= cs.ringBuf.len: ""
  else: ringAt(cs, i)

proc clOnSelect(s: pointer, i: int) {.nimcall.} =
  let cs = cast[ptr ClShell](s)
  if i < 0 or i >= cs.ringBuf.len: return
  let (ok, hit) = tryParseHit(ringAt(cs, i))
  if ok:
    discard runCommand("editor.open", @[hit.file])

proc clProvider(): Provider =
  Provider(
    state: cast[pointer](addr theClShell),
    name: "cl",
    rowCount: clRowCount,
    rowText: clRowText,
    onPaintRow: nil,
    onSelect: clOnSelect,
    onContext: nil,
    onKey: nil,
    onBack: nil)

# ---------- pane swap ----------

proc swapTo(prov: Provider) =
  paneSwapTo(theClPane, prov)

# ---------- run boundary ----------

proc onSentinelLine() =
  let hadHits = theClShell.pendingHits.len > 0
  if theClShell.state == crGrep or hadHits:
    # grep flow batches: hits commit only at the boundary so the panel
    # doesn't churn rows-by-rows while a long grep is still running.
    theGrepState.hits = theClShell.pendingHits
    swapTo(grepProvider())
  # shell flow: lines already streamed into theShellState.lines via
  # streamShellLine; panel already swapped at enterShellMode. Nothing to
  # commit here — just drop the flags.
  theClShell.pendingHits.setLen(0)
  theClShell.state = crIdle

# ---------- drain ----------

proc pushRingLine(line: string) =
  if theClShell.ringBuf.len < ringCap:
    theClShell.ringBuf.add(line)
  else:
    theClShell.ringBuf[theClShell.ringHead] = line
    theClShell.ringHead = (theClShell.ringHead + 1) mod ringCap

proc stripPrompt(line: string): string =
  ## Bash interactive shells emit the prompt and the next command's output
  ## on the same PTY line with no `\n` between them. Find the rightmost
  ## `$ ` or `# ` (the conventional prompt terminator) and return what
  ## sits after it. False-positives on text containing `$ ` literally
  ## are caught downstream by the path heuristic (no `/` → rejected).
  let dollar = line.rfind("$ ")
  let hash = line.rfind("# ")
  let m = max(dollar, hash)
  if m < 0: line
  elif m + 2 >= line.len: ""
  else: line[m + 2 .. ^1]

proc isIgnoredPath(absPath: string): bool =
  ## Drop the hit if any path component matches a name in
  ## `config.grepIgnore` — applied regardless of depth.
  if config.grepIgnore.len == 0: return false
  for part in absPath.split('/'):
    if part.len == 0: continue
    for needle in config.grepIgnore:
      if part == needle: return true
  false

proc shellAutoScroll() =
  if theClPane == nil or theClPane.e.window == nil: return
  let gH = if ui.activeFont != nil: ui.activeFont.glyphHeight else: 16.cint
  let h = theClPane.e.bounds.b - theClPane.e.bounds.t
  let visibleN = max(1, int(h) div max(1, int(gH)))
  let n = theShellState.lines.len
  theClPane.topLine = max(0, n - visibleN)
  elementRepaint(addr theClPane.e, nil)

proc streamShellLine(body: string) =
  theShellState.lines.add(body)
  if theClPane == nil: return
  if theClPane.current.name != "shell":
    swapTo(shellProvider())
  shellAutoScroll()

proc onCompletedLine(raw: string) =
  let clean = stripCsi(raw)
  clLog("line: " & clean)
  if theClShell.sentinel.len > 0 and clean.contains(theClShell.sentinel):
    clLog("  -> sentinel boundary; pendingHits=" & $theClShell.pendingHits.len &
          " state=" & $theClShell.state)
    onSentinelLine()
    return
  pushRingLine(clean)
  let body = stripPrompt(clean)
  let (ok, hit) = tryParseHit(body)
  if ok:
    if isIgnoredPath(hit.file):
      clLog("  -> ignored (grep_ignore): " & hit.file)
    else:
      clLog("  -> hit: " & hit.file & ":" & $hit.line)
      theClShell.pendingHits.add(hit)
  if body.len > 0 and theClShell.state == crShell:
    streamShellLine(body)

proc clShellDrain*() =
  if theClShell.fd < 0: return
  while true:
    let n = read(theClShell.fd,
                 addr theClShell.readBuf[0],
                 theClShell.readBuf.len)
    if n <= 0: break
    for i in 0 ..< n:
      let c = theClShell.readBuf[i]
      if c == '\n':
        onCompletedLine(theClShell.lineBuf)
        theClShell.lineBuf.setLen(0)
      else:
        theClShell.lineBuf.add(c)
    if theClPane != nil and theClPane.current.name == "cl" and
       theClPane.e.window != nil:
      elementRepaint(addr theClPane.e, nil)
    if n < theClShell.readBuf.len: break

# ---------- dispatch ----------

proc hasShellChain(line: string): bool =
  ## True if the line contains tokens that mean "this isn't a bare cd".
  ## We don't tokenize properly — quoting/escaping inside strings is fine
  ## to false-positive on (we just fall through to the shell, which is
  ## the correct behavior for those edge cases).
  if line.contains("&&") or line.contains("||"): return true
  for c in line:
    if c in {';', '|', '`'}: return true
  if line.contains("$("): return true
  false

proc resolveCdTarget(arg: string): string =
  ## Returns absolute path or "" if not resolvable to an existing directory.
  var p = arg
  if p == "~":
    p = getHomeDir()
  elif p.startsWith("~/"):
    p = getHomeDir() / p[2 .. ^1]
  if not isAbsolute(p) and project.projectRoot.len > 0:
    p = project.projectRoot / p
  try:
    p = absolutePath(p).normalizedPath
  except OSError, ValueError:
    return ""
  if dirExists(p): p else: ""

proc enterShellMode(cmd: string) =
  ## Set up state for a path-3 shell run, swap the panel to the shell
  ## provider immediately (so the spinner has a destination before output
  ## arrives), and write the command to the dedicated PTY. Output streams
  ## live into the shell provider via `streamShellLine` from drain.
  theClShell.state = crShell
  theShellState.label = cmd
  theShellState.lines = @[]
  if theClPane != nil:
    theClPane.selected = 0
    theClPane.topLine = 0
    swapTo(shellProvider())
  clShellWrite(cmd)

proc clDispatch*(line: string) =
  let trimmed = line.strip()
  if trimmed.len == 0: return
  clLog("dispatch: '" & trimmed & "' projectRoot=" & project.projectRoot)
  # 0. `t ` prefix — escape hatch. Skip every hijack (registry alias,
  # cd intercept, ls→files, etc.) and pipe the rest straight to the
  # dedicated shell with live output streaming.
  if trimmed.len > 2 and trimmed[0] == 't' and trimmed[1] == ' ':
    let body = trimmed[2 .. ^1].strip()
    if body.len == 0: return
    clLog("  -> t-prefix shell: " & body)
    enterShellMode(body)
    return
  let parts = trimmed.splitWhitespace()
  let name = parts[0]
  let args = if parts.len > 1: parts[1 .. ^1] else: @[]
  # 1. registered IDE command
  if runCommand(name, args):
    clLog("  -> registry hit: " & name)
    return
  # 2. bare `cd <path>` re-anchors the project root
  if name == "cd" and parts.len == 2 and not hasShellChain(trimmed):
    let target = resolveCdTarget(parts[1])
    clLog("  -> cd intercept: target='" & target & "'")
    if target.len > 0:
      discard runCommand("project.load", @[target])
      if theClPane != nil and theClPane.e.window != nil:
        elementFocus(addr theClPane.e)
      return
  # 3. fall through to the dedicated shell — live-stream output.
  clLog("  -> shell fallthrough")
  enterShellMode(trimmed)

# ---------- install ----------

proc cmdGrep(args: seq[string]) =
  ## :grep <pattern> — strips any leading flag tokens (anything starting
  ## with `-`) and substitutes our own (`grep -rn --color=never`). User's
  ## remaining tokens are joined as the pattern.
  if theClShell.fd < 0 or project.projectRoot.len == 0:
    clLog("grep skipped: fd=" & $theClShell.fd & " root='" & project.projectRoot & "'")
    return
  var patternParts: seq[string] = @[]
  for a in args:
    if a.len > 0 and a[0] == '-': continue
    patternParts.add(a)
  if patternParts.len == 0: return
  let pattern = patternParts.join(" ")
  theGrepState.lastQuery = pattern
  theClShell.state = crGrep
  var cmd = "grep -rn --color=never"
  for ignore in config.grepIgnore:
    cmd.add(" --exclude-dir=" & quoteShell(ignore))
  cmd.add(" -- " & quoteShell(pattern))
  cmd.add(" " & quoteShell(project.projectRoot))
  clShellWrite(cmd)

proc clShellInstall*(pane: ptr ResultsPane) =
  theClPane = pane
  commands.clDispatchCb = proc(line: string) = clDispatch(line)
  registerCommand("cl", proc(args: seq[string]) = swapTo(clProvider()))
  registerCommand("grep", cmdGrep)
  # Hijack `ls` → `files`. Registry runs before the shell fall-through, so
  # typing `ls` (with or without args) lands on the tree provider instead.
  # Escape hatch: invoke the real binary via `/bin/ls`, which doesn't
  # match the registered name and falls through to the dedicated shell.
  registerCommand("ls", proc(args: seq[string]) =
    if args.len == 0:
      discard runCommand("files")
    else:
      enterShellMode("ls " & args.join(" ")))

# ---------- spinner ----------

proc clShellRunning*(): bool = theClShell.state != crIdle

proc clShellSpinnerChar*(): char =
  const frames: array[4, char] = ['|', '/', '-', '\\']
  let idx = (monoNs() div 100_000_000) mod 4
  frames[int(idx)]

# ---------- shift polling (drives the grep header path expansion) ----------

proc clTickShift*(win: ptr Window) =
  ## Poll the held-shift state once per pump tick. When it flips and the
  ## panel is currently showing grep, repaint so the header text swaps
  ## live between ".../foo.txt" and the full path.
  let now = (win != nil and win.shift)
  if now == theShiftHeld: return
  theShiftHeld = now
  if theClPane != nil and theClPane.current.name == "grep" and
     theClPane.e.window != nil:
    elementRepaint(addr theClPane.e, nil)
