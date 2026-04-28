import std/[os, strutils]
import posix
import luigi
import pty, project, font, config, clipboard, theme
when defined(termDebug):
  import termdebug
  export termdebug.ParserState

{.compile: "../vendor/libtmt/tmt.c".}
{.passC: "-I\"" & (currentSourcePath.parentDir.parentDir / "vendor" / "libtmt") & "\"".}

type
  TMT* {.importc, incompleteStruct, header: "tmt.h".} = object
  TmtColor = cint
  TmtAttrs {.importc: "TMTATTRS", header: "tmt.h", bycopy.} = object
    bold, dim, underline, blink, reverse, invisible: bool
    fg, bg: TmtColor
  TmtChar {.importc: "TMTCHAR", header: "tmt.h", bycopy.} = object
    c: cint
    a: TmtAttrs
  TmtLine {.importc: "TMTLINE", header: "tmt.h", bycopy.} = object
    dirty: bool
    chars: UncheckedArray[TmtChar]
  TmtScreen {.importc: "TMTSCREEN", header: "tmt.h", bycopy.} = object
    nline, ncol: csize_t
    lines: ptr UncheckedArray[ptr TmtLine]
  TmtPoint {.importc: "TMTPOINT", header: "tmt.h", bycopy.} = object
    r, c: csize_t

proc tmt_open(nline, ncol: csize_t, cb: pointer, p: pointer, acs: ptr cint): ptr TMT {.importc, header: "tmt.h".}
proc tmt_close(vt: ptr TMT) {.importc, header: "tmt.h".}
proc tmt_resize(vt: ptr TMT, nline, ncol: csize_t): bool {.importc, header: "tmt.h", discardable.}
proc tmt_write(vt: ptr TMT, s: cstring, n: csize_t) {.importc, header: "tmt.h".}
proc tmt_screen(vt: ptr TMT): ptr TmtScreen {.importc, header: "tmt.h".}
proc tmt_cursor(vt: ptr TMT): ptr TmtPoint {.importc, header: "tmt.h".}
proc tmt_clean(vt: ptr TMT) {.importc, header: "tmt.h".}

type
  ScrollLine = seq[TmtChar]

  Terminal* = object
    e*: Element
    name*: string
    locked*: bool
    cwd*: string
    rows, cols: int
    vt: ptr TMT
    ptyFd*: cint
    pid*: Pid
    readBuf: array[4096, char]
    selAnchorR, selAnchorC: int
    selEndR, selEndC: int
    hasSel: bool
    cursorVisible*: bool
    history: seq[ScrollLine]
    scrollOffset: int  # 0 = live; N = N lines scrolled back into history
    when defined(termDebug):
      dbgParser*: ParserState

const
  scrollbackMax = 2000
  scrollbackOver = 256  # trim only when this many over the cap, amortizing the slice

# tmt_msg_t enum values, mirrored from tmt.h.
const
  TMT_MSG_CURSOR = cint(4)

proc tmtCallback(m: cint, vt: ptr TMT, a: pointer, p: pointer) {.cdecl.} =
  let t = cast[ptr Terminal](p)
  if t == nil: return
  if m == TMT_MSG_CURSOR and a != nil:
    let s = cast[cstring](a)
    t.cursorVisible = (s[0] == 't')

var allTerminals*: seq[ptr Terminal]

proc colorOf(c: TmtColor, fg: bool): uint32 =
  # libtmt encodes ANSI colors as 1..8 (BLACK..WHITE); 0 / out-of-range = DEFAULT.
  let p = currentPalette
  case int(c)
  of 1: p.borderDark    # BLACK
  of 2: p.urgent        # RED
  of 3: p.codeType      # GREEN
  of 4: p.codeString    # YELLOW
  of 5: p.accent        # BLUE
  of 6: p.codeKeyword   # MAGENTA
  of 7: p.codeReturnType # CYAN
  of 8: p.fg            # WHITE
  else: (if fg: p.fg else: p.bg)

proc captureScreen(t: ptr Terminal): seq[ScrollLine] =
  if t.vt == nil: return
  let scr = tmt_screen(t.vt)
  let nrow = int(scr.nline)
  let ncol = int(scr.ncol)
  result = newSeq[ScrollLine](nrow)
  for r in 0 ..< nrow:
    let line = scr.lines[r]
    var row = newSeq[TmtChar](ncol)
    for c in 0 ..< ncol:
      row[c] = line.chars[c]
    result[r] = row

proc rowsEqualChars(a: ScrollLine, b: ptr TmtLine, ncol: int): bool =
  if a.len != ncol: return false
  for c in 0 ..< ncol:
    if a[c].c != b.chars[c].c: return false
  true

proc rowIsBlank(a: ScrollLine): bool =
  for ch in a:
    let c = ch.c
    if c != cint(' ') and c != cint(0): return false
  true

proc lineIsBlank(b: ptr TmtLine, ncol: int): bool =
  for c in 0 ..< ncol:
    let ch = b.chars[c].c
    if ch != cint(' ') and ch != cint(0): return false
  true

proc rowHasGlyph(a: ScrollLine): bool = not rowIsBlank(a)

proc detectScroll(t: ptr Terminal, old: seq[ScrollLine]) =
  ## Diff pre-write grid vs post-write grid and push rows that genuinely
  ## scrolled off the top into history. libtmt has no scroll callback so
  ## we infer it; this is a heuristic that intentionally errs toward NOT
  ## capturing — TUIs (claude code, vim, htop) repaint the whole screen
  ## per keystroke, and false positives pollute scrollback with bits of
  ## the live UI (input bar, status line) "above" real history.
  ##
  ## A real terminal scroll-by-k satisfies all of:
  ##   1) old[k..nrow-1] matches new[0..nrow-1-k] **counting blanks as
  ##      mismatches when neither side is blank** (blank-vs-blank is too
  ##      cheap a match — a TUI repaint with mostly-empty rows would
  ##      otherwise pick a small k off pure coincidence).
  ##   2) at least one of the matched rows contains a non-blank char
  ##      (otherwise we're matching empty space against empty space).
  ##   3) the freshly-revealed bottom rows (new[nrow-k..nrow-1]) carry
  ##      content. If they're all blank, the screen just got cleared —
  ##      not a scroll.
  ##   4) the rows we'd push (old[0..k-1]) carry content. Blank rows in
  ##      history are noise; we drop them rather than capture them.
  if t.vt == nil or old.len == 0: return
  let scr = tmt_screen(t.vt)
  let nrow = int(scr.nline)
  let ncol = int(scr.ncol)
  if old.len != nrow: return
  # No-op write: top row unchanged → no scroll.
  if rowsEqualChars(old[0], scr.lines[0], ncol): return
  var k = 0
  var bestMatchedGlyphs = 0
  for tryK in 1 ..< nrow:
    var ok = true
    var matchedGlyphs = 0
    for i in 0 ..< (nrow - tryK):
      let oldRowBlank = rowIsBlank(old[i + tryK])
      let newRowBlank = lineIsBlank(scr.lines[i], ncol)
      if oldRowBlank and newRowBlank:
        # Both blank — accept but don't count as evidence. Pure-blank
        # bands match accidentally between independent screen states.
        continue
      if oldRowBlank != newRowBlank:
        ok = false; break
      if not rowsEqualChars(old[i + tryK], scr.lines[i], ncol):
        ok = false; break
      inc matchedGlyphs
    if ok and matchedGlyphs > 0:
      k = tryK
      bestMatchedGlyphs = matchedGlyphs
      break
  if k == 0 or bestMatchedGlyphs == 0: return
  # Bottom k rows must carry content for it to be a real scroll. A
  # full-screen clear would otherwise look like a scroll-by-everything.
  var bottomHasContent = false
  for i in (nrow - k) ..< nrow:
    if not lineIsBlank(scr.lines[i], ncol):
      bottomHasContent = true; break
  if not bottomHasContent: return
  # Push only non-blank rows. Blank rows in history are visual noise that
  # makes pageup feel like "ton of empty injected lines".
  for i in 0 ..< k:
    if rowHasGlyph(old[i]):
      t.history.add(old[i])
  if t.history.len > scrollbackMax + scrollbackOver:
    let dropN = t.history.len - scrollbackMax
    t.history = t.history[dropN .. ^1]
  # Live writes always snap the viewport to the bottom; preserve the
  # invariant that scrolled-back content stays visually anchored by
  # increasing the offset by k (so the user keeps seeing what they scrolled to).
  if t.scrollOffset > 0:
    t.scrollOffset = min(t.history.len, t.scrollOffset + k)

proc selOrdered(t: ptr Terminal): tuple[sR, sC, eR, eC: int] =
  let aR = t.selAnchorR; let aC = t.selAnchorC
  let bR = t.selEndR;    let bC = t.selEndC
  if (aR < bR) or (aR == bR and aC <= bC): (aR, aC, bR, bC)
  else: (bR, bC, aR, aC)

proc inSel(t: ptr Terminal, r, c: int): bool =
  if not t.hasSel: return false
  let (sR, sC, eR, eC) = selOrdered(t)
  if r < sR or r > eR: return false
  if r == sR and r == eR: return c >= sC and c < eC
  if r == sR: return c >= sC
  if r == eR: return c < eC
  true   # fully-selected interior row

proc selCopyText(t: ptr Terminal): string =
  if t.vt == nil or not t.hasSel: return ""
  let scr = tmt_screen(t.vt)
  let nrow = int(scr.nline)
  let ncol = int(scr.ncol)
  let (sR, sC, eR, eC) = selOrdered(t)
  var rows: seq[string] = @[]
  for r in max(0, sR) .. min(nrow - 1, eR):
    let line = scr.lines[r]
    let lo =
      if r == sR: max(0, sC) else: 0
    let hi =
      if r == eR: min(ncol, eC) else: ncol
    var row = ""
    for c in lo ..< hi:
      var ch = int(line.chars[c].c)
      if ch < 32 or ch > 126: ch = 32
      row.add(char(ch))
    # Trim trailing spaces per row — terminals pad with spaces to ncol.
    var k = row.len
    while k > 0 and row[k - 1] == ' ': dec k
    row.setLen(k)
    rows.add(row)
  rows.join("\n")

proc cellAt(t: ptr Terminal, px, py: cint): tuple[r, c: int] =
  let (gW, gH) = glyphDims()
  let lx = max(cint(0), px - t.e.bounds.l)
  let ly = max(cint(0), py - t.e.bounds.t)
  let r = min(t.rows - 1, max(0, int(ly div max(cint(1), gH))))
  let c = min(t.cols - 1, max(0, int(lx div max(cint(1), gW))))
  (r, c)

proc terminalMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let t = cast[ptr Terminal](element)
  if message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let (r, c) = cellAt(t, w.cursorX, w.cursorY)
      t.selAnchorR = r; t.selAnchorC = c
      t.selEndR = r;    t.selEndC = c
      t.hasSel = false
      elementRepaint(element, nil)
    return 1

  if message == msgMouseDrag:
    let w = element.window
    if w != nil:
      let (r, c) = cellAt(t, w.cursorX, w.cursorY)
      t.selEndR = r; t.selEndC = c
      t.hasSel = (t.selAnchorR != r or t.selAnchorC != c)
      if t.hasSel:
        clipboardSetPrimary(selCopyText(t))
      elementRepaint(element, nil)
    return 1

  if message == msgUpdate:
    elementRepaint(element, nil)
    return 0

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    if t.vt == nil: return 0
    let scr = tmt_screen(t.vt)
    let cur = tmt_cursor(t.vt)
    let (gW, gH) = glyphDims()
    let bx = t.e.bounds.l
    let by = t.e.bounds.t
    var buf: array[2, char]
    buf[1] = '\0'
    let drawCursor = t.cursorVisible and
                     element.window != nil and
                     element.window.focused == element
    let nrow = int(scr.nline)
    let ncol = int(scr.ncol)
    let histLines = min(t.scrollOffset, t.history.len)
    for r in 0 ..< nrow:
      let isHist = r < histLines
      let liveR = r - histLines
      var hLine: ScrollLine
      var line: ptr TmtLine = nil
      if isHist:
        hLine = t.history[t.history.len - histLines + r]
      else:
        line = scr.lines[liveR]
      for col in 0 ..< ncol:
        let cell =
          if isHist:
            (if col < hLine.len: hLine[col] else: TmtChar(c: cint(' ')))
          else:
            line.chars[col]
        let x = bx + cint(col) * gW
        let y = by + cint(r) * gH
        var fg = colorOf(cell.a.fg, true)
        var bg = colorOf(cell.a.bg, false)
        if cell.a.reverse: swap(fg, bg)
        if not isHist and drawCursor and int(cur.r) == liveR and int(cur.c) == col:
          swap(fg, bg)
        if not isHist and inSel(t, liveR, col):
          bg = ui.theme.selected
        drawBlock(painter, Rectangle(l: x, r: x + gW, t: y, b: y + gH), bg)
        let ch = cell.c
        if ch <= 32 or ch == 0x7F:
          discard  # blank cell
        elif ch <= 126:
          buf[0] = char(ch)
          drawString(painter,
            Rectangle(l: x, r: x + gW, t: y, b: y + gH),
            cast[cstring](addr buf[0]), 1,
            fg, cint(ALIGN_LEFT), nil)
        else:
          drawGlyphCp(painter, x, y, ch, fg)
    if element.window != nil and element.window.focused == element:
      let b = t.e.bounds
      drawBorder(painter, b, currentPalette.accent, Rectangle(l: 2, r: 2, t: 2, b: 2))
    tmt_clean(t.vt)
    return 1

  elif message == msgMouseWheel:
    # di > 0 = wheel down (toward live); di < 0 = wheel up (back in history).
    # Step is roughly one line per notch on a typical mouse.
    let step = -(int(di) div 40)
    let newOff = clamp(t.scrollOffset + step, 0, t.history.len)
    if newOff != t.scrollOffset:
      t.scrollOffset = newOff
      elementRepaint(element, nil)
      return 1
    # At the limit — let the parent stack scroll between terminals.
    return 0

  elif message == msgLayout:
    let w = t.e.bounds.r - t.e.bounds.l
    let h = t.e.bounds.b - t.e.bounds.t
    let (gW, gH) = glyphDims()
    let newCols = max(4, int(w) div max(1, int(gW)))
    let newRows = max(1, int(h) div max(1, int(gH)))
    if newCols != t.cols or newRows != t.rows:
      t.cols = newCols
      t.rows = newRows
      if t.vt != nil:
        tmt_resize(t.vt, csize_t(t.rows), csize_t(t.cols))
      if t.ptyFd >= 0:
        pty.resize(t.ptyFd, t.rows, t.cols)
    return 0

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    if t.ptyFd < 0: return 0
    let w = element.window
    if w != nil and w.alt: return 0
    let ctrl  = (w != nil and w.ctrl)
    let shift = (w != nil and w.shift)
    let code = k.code

    # --- Ctrl+Shift+Up/Down scroll the scrollback buffer -----------------
    if ctrl and shift and (code == int(KEYCODE_UP) or code == int(KEYCODE_DOWN)):
      let pageStep = max(1, t.rows div 2)
      let delta = if code == int(KEYCODE_UP): pageStep else: -pageStep
      let newOff = clamp(t.scrollOffset + delta, 0, t.history.len)
      if newOff != t.scrollOffset:
        t.scrollOffset = newOff
        elementRepaint(element, nil)
      return 1

    # --- Shift+arrow extends selection over the visible grid -------------
    # Done before PTY pass-through so vim/tmux inside the terminal don't see
    # these. Tradeoff is documented; a config knob can ungate later.
    let isArrow = code == int(KEYCODE_LEFT) or code == int(KEYCODE_RIGHT) or
                  code == int(KEYCODE_UP) or code == int(KEYCODE_DOWN) or
                  code == int(KEYCODE_HOME) or code == int(KEYCODE_END)
    if shift and not ctrl and isArrow:
      if not t.hasSel:
        # Anchor at the current libtmt cursor (where the user last looked).
        if t.vt != nil:
          let cur = tmt_cursor(t.vt)
          t.selAnchorR = int(cur.r); t.selAnchorC = int(cur.c)
          t.selEndR = t.selAnchorR; t.selEndC = t.selAnchorC
        t.hasSel = true
      var nr = t.selEndR
      var nc = t.selEndC
      if code == int(KEYCODE_LEFT):
        if nc > 0: dec nc
        elif nr > 0: dec nr; nc = t.cols - 1
      elif code == int(KEYCODE_RIGHT):
        if nc < t.cols - 1: inc nc
        elif nr < t.rows - 1: inc nr; nc = 0
      elif code == int(KEYCODE_UP):
        if nr > 0: dec nr
      elif code == int(KEYCODE_DOWN):
        if nr < t.rows - 1: inc nr
      elif code == int(KEYCODE_HOME):
        nc = 0
      elif code == int(KEYCODE_END):
        nc = t.cols - 1
      t.selEndR = nr; t.selEndC = nc
      if t.selEndR == t.selAnchorR and t.selEndC == t.selAnchorC:
        t.hasSel = false
      if t.hasSel:
        clipboardSetPrimary(selCopyText(t))
      elementRepaint(element, nil)
      return 1

    # --- IDE / legacy copy-paste remap ----------------------------------
    if ctrl and code == int(KEYCODE_LETTER('C')):
      # INTR byte; the slave's line discipline (ISIG) turns it into SIGINT
      # delivered to the foreground process group, so TUIs running inside
      # the shell (claude, vim) actually see the interrupt. Killing t.pid
      # would only signal the shell, which usually swallows it.
      let intr = "\x03"
      case config.terminalCopyPaste
      of tcpIde:
        if shift:
          # Force-interrupt escape hatch even when a selection is held.
          discard write(t.ptyFd, intr.cstring, 1)
        elif t.hasSel:
          clipboardSetBoth(selCopyText(t))
        else:
          discard write(t.ptyFd, intr.cstring, 1)
        return 1
      of tcpLegacy:
        if shift:
          if t.hasSel: clipboardSetBoth(selCopyText(t))
          return 1
        # Plain Ctrl+C falls through to PTY pass-through below (SIGINT).
    if ctrl and code == int(KEYCODE_LETTER('V')):
      case config.terminalCopyPaste
      of tcpIde:
        let txt = clipboardGet()
        if txt.len > 0:
          discard write(t.ptyFd, txt.cstring, txt.len)
        return 1
      of tcpLegacy:
        if shift:
          let txt = clipboardGet()
          if txt.len > 0:
            discard write(t.ptyFd, txt.cstring, txt.len)
          return 1
        # Plain Ctrl+V falls through (literal-quote in some apps).

    var seqStr: string = ""
    if code == int(KEYCODE_LEFT):        seqStr = "\x1b[D"
    elif code == int(KEYCODE_RIGHT):     seqStr = "\x1b[C"
    elif code == int(KEYCODE_UP):        seqStr = "\x1b[A"
    elif code == int(KEYCODE_DOWN):      seqStr = "\x1b[B"
    elif code == int(KEYCODE_HOME):      seqStr = "\x1b[H"
    elif code == int(KEYCODE_END):       seqStr = "\x1b[Y"
    elif code == int(KEYCODE_ENTER):     seqStr = "\r"
    elif code == int(KEYCODE_BACKSPACE): seqStr = "\x7f"
    elif code == int(KEYCODE_ESCAPE):    seqStr = "\x1b"
    elif code == int(KEYCODE_TAB):
      # Shift+Tab → CSI Z ("back tab"); TUIs (claude, vim, readline) key off this.
      seqStr = if shift: "\x1b[Z" else: "\t"
    # Only an actual byte-producing keypress should clear the selection;
    # standalone modifier holds (Ctrl by itself, Shift by itself) must not,
    # otherwise Ctrl+C never sees the selection.
    let producesBytes = seqStr.len > 0 or k.textBytes > 0
    if producesBytes and t.hasSel:
      t.hasSel = false
    if producesBytes and t.scrollOffset > 0:
      t.scrollOffset = 0
    if seqStr.len > 0:
      discard write(t.ptyFd, seqStr.cstring, seqStr.len)
    elif k.textBytes > 0:
      discard write(t.ptyFd, k.text, int(k.textBytes))
    if producesBytes: elementRepaint(element, nil)
    return 1

  elif message == msgDestroy:
    if t.vt != nil:
      tmt_close(t.vt); t.vt = nil
    if t.ptyFd >= 0:
      discard close(t.ptyFd); t.ptyFd = -1
    if t.pid > 0:
      discard kill(t.pid, SIGTERM)
      var st: cint
      discard waitpid(t.pid, st, WNOHANG)
      t.pid = Pid(-1)
    for i, p in allTerminals:
      if p == t:
        allTerminals.del(i); break
    return 0

  return 0

proc terminalCreate*(parent: ptr Element, flags: uint32 = 0): ptr Terminal =
  let e = elementCreate(csize_t(sizeof(Terminal)), parent, flags or ELEMENT_TAB_STOP,
                        terminalMessage, "Terminal")
  let t = cast[ptr Terminal](e)
  t.rows = 24; t.cols = 80
  t.cursorVisible = true
  t.vt = tmt_open(csize_t(t.rows), csize_t(t.cols),
                  cast[pointer](tmtCallback), cast[pointer](t), nil)
  let (fd, pid) = startShell(t.rows, t.cols, project.projectRoot,
                             config.terminalTerm)
  t.ptyFd = fd
  t.pid = pid
  allTerminals.add(t)
  return t

proc termWrite*(t: ptr Terminal, s: string) =
  if t == nil or t.vt == nil or s.len == 0: return
  let snap = captureScreen(t)
  tmt_write(t.vt, s.cstring, csize_t(s.len))
  detectScroll(t, snap)
  elementRepaint(addr t.e, nil)

proc termRunCmd*(t: ptr Terminal, line: string) =
  ## Write a command line into the PTY, appending a newline.
  if t == nil or t.ptyFd < 0 or line.len == 0: return
  let payload = line & "\n"
  discard write(t.ptyFd, payload.cstring, payload.len)

proc termRefreshCwd*(t: ptr Terminal) =
  ## Cheap readlink on /proc/<pid>/cwd. Updates the cached cwd for the
  ## per-terminal title bar. No-op if the proc is gone.
  if t == nil or t.pid <= 0: return
  let p = "/proc/" & $cint(t.pid) & "/cwd"
  try:
    t.cwd = expandSymlink(p)
  except OSError, IOError:
    discard

when defined(termDebug):
  proc terminalIndex*(t: ptr Terminal): int =
    for i, p in allTerminals:
      if p == t: return i
    -1

proc drainAll*() =
  for t in allTerminals:
    if t.ptyFd < 0 or t.vt == nil: continue
    while true:
      let n = read(t.ptyFd, addr t.readBuf[0], t.readBuf.len)
      if n <= 0: break
      when defined(termDebug):
        dbgRecordRead(terminalIndex(t), t.dbgParser,
                      addr t.readBuf[0], n.int)
      let snap = captureScreen(t)
      tmt_write(t.vt, cast[cstring](addr t.readBuf[0]), csize_t(n))
      detectScroll(t, snap)
      elementRepaint(addr t.e, nil)
      if n < t.readBuf.len: break

when defined(termDebug):
  proc termDebugDump*(t: ptr Terminal) =
    if t == nil or t.vt == nil: return
    let scr = tmt_screen(t.vt)
    let cur = tmt_cursor(t.vt)
    let nrow = int(scr.nline)
    let ncol = int(scr.ncol)
    let cellAt = proc(r, c: int): int32 =
      if r < 0 or r >= nrow or c < 0 or c >= ncol: return 0'i32
      int32(scr.lines[r].chars[c].c)
    let reverseAt = proc(r, c: int): bool =
      if r < 0 or r >= nrow or c < 0 or c >= ncol: return false
      scr.lines[r].chars[c].a.reverse
    dbgDumpGrid(terminalIndex(t), nrow, ncol,
                int(cur.r), int(cur.c), cellAt, reverseAt)
