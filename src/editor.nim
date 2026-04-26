import std/[os, strutils]
import luigi, config, font, highlight

type
  EditorBuf* = object
    lines: seq[string]
    cursorRow, cursorCol: int
    topLine: int
    path: string
    dirty: bool
    mode: CursorMode
    syntax: ptr SyntaxRule
    lineStartStates: seq[uint8]   # 1 byte per line (tokenizer entry state)
    dirtyFromRow: int             # min row whose entry state may be stale
    spans: seq[Span]              # reused per-paint buffer

  Editor* = object
    e*: Element
    tabs*: seq[EditorBuf]
    activeIdx*: int

var
  theEditor*: ptr Editor
  cursorBlinkOn*: bool = true

template buf(ed: ptr Editor): var EditorBuf = ed.tabs[ed.activeIdx]

const
  tabPadX: cint = 8
  tabPadY: cint = 3

proc tabStripHeight(): cint =
  let (_, gH) = glyphDims()
  gH + 2 * tabPadY

proc tabLabel(b: EditorBuf): string =
  let nm = if b.path.len == 0: "[scratch]" else: extractFilename(b.path)
  if b.dirty: "* " & nm else: nm

proc gutterWidth(ed: ptr Editor): cint =
  if config.lineNumbers == lnmOff: return 0
  let (gW, _) = glyphDims()
  let n = max(ed.buf.lines.len, 100)
  var d = 1
  var v = n
  while v >= 10:
    inc d
    v = v div 10
  cint(d + 1) * gW

proc invalidateFrom(ed: ptr Editor, row: int) =
  if row < ed.buf.dirtyFromRow: ed.buf.dirtyFromRow = row

proc refreshStates(ed: ptr Editor, throughRow: int) =
  ## lineStartStates[i] is the tokenizer entry state for line i (1 = inside a
  ## block comment carried over from line i-1). Walks from dirtyFromRow up to
  ## throughRow, updating downstream entries.
  let n = ed.buf.lines.len
  if n == 0:
    ed.buf.lineStartStates.setLen(0)
    ed.buf.dirtyFromRow = 0
    return
  if ed.buf.lineStartStates.len != n:
    ed.buf.lineStartStates.setLen(n)   # extend with 0s or truncate
  if ed.buf.dirtyFromRow >= n: return
  if ed.buf.dirtyFromRow <= 0:
    ed.buf.lineStartStates[0] = 0
    ed.buf.dirtyFromRow = 0
  let stop = min(throughRow, n - 1)
  var i = ed.buf.dirtyFromRow
  while i <= stop:
    let entry = ed.buf.lineStartStates[i]
    let next = highlight.advanceState(ed.buf.lines[i], ed.buf.syntax, entry)
    if i + 1 < n:
      ed.buf.lineStartStates[i + 1] = next
    inc i
  ed.buf.dirtyFromRow = stop + 1

proc visibleRows(ed: ptr Editor): int =
  let (_, gH) = glyphDims()
  let avail = max(0, int(ed.e.bounds.b - ed.e.bounds.t) - int(tabStripHeight()))
  max(1, avail div max(1, int(gH)))

proc clampCursor(ed: ptr Editor) =
  if ed.buf.lines.len == 0:
    ed.buf.lines.add("")
  if ed.buf.cursorRow < 0: ed.buf.cursorRow = 0
  if ed.buf.cursorRow >= ed.buf.lines.len:
    ed.buf.cursorRow = ed.buf.lines.len - 1
  let ll = ed.buf.lines[ed.buf.cursorRow].len
  if ed.buf.cursorCol < 0: ed.buf.cursorCol = 0
  if ed.buf.cursorCol > ll: ed.buf.cursorCol = ll

proc followCursor(ed: ptr Editor) =
  let vr = visibleRows(ed)
  if ed.buf.cursorRow < ed.buf.topLine:
    ed.buf.topLine = ed.buf.cursorRow
  elif ed.buf.cursorRow >= ed.buf.topLine + vr:
    ed.buf.topLine = ed.buf.cursorRow - vr + 1
  if ed.buf.topLine < 0: ed.buf.topLine = 0

proc saveAtomic(path, content: string): bool =
  try:
    let tmp = path & ".prawk-tmp"
    writeFile(tmp, content)
    moveFile(tmp, path)
    return true
  except IOError, OSError:
    return false

proc loadIntoBuf(b: var EditorBuf, path: string) =
  b.path = path
  b.lines = @[]
  b.cursorRow = 0
  b.cursorCol = 0
  b.topLine = 0
  b.dirty = false
  b.mode = config.cursorMode
  b.syntax = highlight.syntaxForPath(path)
  b.lineStartStates.setLen(0)
  b.dirtyFromRow = 0
  if fileExists(path):
    try:
      let content = readFile(path)
      b.lines = content.splitLines()
    except IOError:
      discard
  if b.lines.len == 0:
    b.lines.add("")

proc findTab(ed: ptr Editor, path: string): int =
  for i in 0 ..< ed.tabs.len:
    if ed.tabs[i].path == path: return i
  -1

proc editorOpenFile*(ed: ptr Editor, path: string) =
  let existing = findTab(ed, path)
  if existing >= 0:
    ed.activeIdx = existing
    if path.len > 0:
      config.pushRecent("recents.files", path)
    elementRepaint(addr ed.e, nil)
    return
  # Replace the empty starter scratch tab in-place if present and unmodified.
  let scratchOnly = ed.tabs.len == 1 and ed.tabs[0].path.len == 0 and
                    not ed.tabs[0].dirty and ed.tabs[0].lines.len == 1 and
                    ed.tabs[0].lines[0].len == 0
  if scratchOnly:
    loadIntoBuf(ed.tabs[0], path)
    ed.activeIdx = 0
  else:
    var nb: EditorBuf
    loadIntoBuf(nb, path)
    ed.tabs.add(nb)
    ed.activeIdx = ed.tabs.len - 1
  if path.len > 0:
    config.pushRecent("recents.files", path)
  elementRepaint(addr ed.e, nil)

proc editorIsDirty*(): bool =
  if theEditor == nil: return false
  for t in theEditor.tabs:
    if t.dirty: return true
  false

proc editorForceOpenFile*(path: string) =
  if theEditor != nil:
    editorOpenFile(theEditor, path)

proc editorCloseTab*(ed: ptr Editor, idx: int) =
  if idx < 0 or idx >= ed.tabs.len: return
  ed.tabs.delete(idx)
  if ed.tabs.len == 0:
    var empty: EditorBuf
    loadIntoBuf(empty, "")
    ed.tabs.add(empty)
    ed.activeIdx = 0
  else:
    if ed.activeIdx >= ed.tabs.len:
      ed.activeIdx = ed.tabs.len - 1
    elif idx < ed.activeIdx:
      dec ed.activeIdx
  elementRepaint(addr ed.e, nil)

proc editorTabNext*(ed: ptr Editor) =
  if ed == nil or ed.tabs.len <= 1: return
  ed.activeIdx = (ed.activeIdx + 1) mod ed.tabs.len
  elementRepaint(addr ed.e, nil)

proc editorTabPrev*(ed: ptr Editor) =
  if ed == nil or ed.tabs.len <= 1: return
  ed.activeIdx = (ed.activeIdx - 1 + ed.tabs.len) mod ed.tabs.len
  elementRepaint(addr ed.e, nil)

proc insertText(ed: ptr Editor, s: string) =
  if s.len == 0: return
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1) & s & line.substr(col)
  ed.buf.cursorCol = col + s.len
  ed.buf.dirty = true
  invalidateFrom(ed, row)

proc insertNewline(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1)
  ed.buf.lines.insert(line.substr(col), row + 1)
  ed.buf.cursorRow = row + 1
  ed.buf.cursorCol = 0
  ed.buf.dirty = true
  invalidateFrom(ed, row)

proc backspace(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  if col > 0:
    let line = ed.buf.lines[row]
    ed.buf.lines[row] = line.substr(0, col - 2) & line.substr(col)
    ed.buf.cursorCol = col - 1
    ed.buf.dirty = true
    invalidateFrom(ed, row)
  elif row > 0:
    let prev = ed.buf.lines[row - 1]
    let cur = ed.buf.lines[row]
    ed.buf.cursorCol = prev.len
    ed.buf.lines[row - 1] = prev & cur
    ed.buf.lines.delete(row)
    ed.buf.cursorRow = row - 1
    ed.buf.dirty = true
    invalidateFrom(ed, row - 1)

proc killToEnd(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  if col < line.len:
    ed.buf.lines[row] = line.substr(0, col - 1)
    ed.buf.dirty = true
    invalidateFrom(ed, row)

proc saveCurrent*(ed: ptr Editor) =
  if ed.buf.path.len == 0: return
  let content = ed.buf.lines.join("\n")
  if saveAtomic(ed.buf.path, content):
    ed.buf.dirty = false

proc activeMode*(ed: ptr Editor): CursorMode =
  if ed == nil or ed.tabs.len == 0: cmInsert
  else: ed.tabs[ed.activeIdx].mode

proc editorJumpAbsolute*(ed: ptr Editor, line: int) =
  if ed == nil: return
  ed.buf.cursorRow = line - 1   # 1-based input
  clampCursor(ed)
  followCursor(ed)
  elementRepaint(addr ed.e, nil)

proc editorJumpRelative*(ed: ptr Editor, delta: int) =
  if ed == nil: return
  ed.buf.cursorRow += delta
  clampCursor(ed)
  followCursor(ed)
  elementRepaint(addr ed.e, nil)

proc editorTabCount*(ed: ptr Editor): int =
  if ed == nil: 0 else: ed.tabs.len

proc editorTabIsDirty*(ed: ptr Editor, idx: int): bool =
  if ed == nil or idx < 0 or idx >= ed.tabs.len: false
  else: ed.tabs[idx].dirty

proc editorTabCloseForce*(ed: ptr Editor, idx: int) =
  if ed == nil or idx < 0 or idx >= ed.tabs.len: return
  ed.tabs[idx].dirty = false
  editorCloseTab(ed, idx)

proc editorActiveIdx*(ed: ptr Editor): int =
  if ed == nil: 0 else: ed.activeIdx

proc paintTabStrip(ed: ptr Editor, painter: ptr Painter) =
  let (gW, _) = glyphDims()
  let by = ed.e.bounds.t
  let stripH = tabStripHeight()
  let stripRect = Rectangle(l: ed.e.bounds.l, r: ed.e.bounds.r,
                            t: by, b: by + stripH)
  drawBlock(painter, stripRect, ui.theme.panel2)
  var x = ed.e.bounds.l
  for i in 0 ..< ed.tabs.len:
    let label = tabLabel(ed.tabs[i])
    let w = cint(label.len) * gW + 2 * tabPadX
    if x >= ed.e.bounds.r: break
    let r = Rectangle(l: x, r: min(x + w, ed.e.bounds.r),
                      t: by, b: by + stripH)
    let active = (i == ed.activeIdx)
    let bg = if active: ui.theme.selected else: ui.theme.panel2
    drawBlock(painter, r, bg)
    let fg = if active: ui.theme.textSelected else: ui.theme.text
    drawString(painter, r, label.cstring, label.len, fg, cint(ALIGN_CENTER), nil)
    x += w
  # bottom border under strip
  drawBlock(painter,
            Rectangle(l: ed.e.bounds.l, r: ed.e.bounds.r,
                      t: by + stripH - 1, b: by + stripH),
            ui.theme.border)

proc tabAtX(ed: ptr Editor, lx: cint): int =
  let (gW, _) = glyphDims()
  var x: cint = 0
  for i in 0 ..< ed.tabs.len:
    let label = tabLabel(ed.tabs[i])
    let w = cint(label.len) * gW + 2 * tabPadX
    if lx >= x and lx < x + w: return i
    x += w
  -1

proc paintGutter(ed: ptr Editor, painter: ptr Painter,
                 contentTop: cint, gW, gH: cint, vr: int, gutterW: cint) =
  let bx = ed.e.bounds.l
  let gutterRect = Rectangle(l: bx, r: bx + gutterW,
                             t: contentTop, b: ed.e.bounds.b)
  drawBlock(painter, gutterRect, ui.theme.panel2)
  for i in 0 ..< vr:
    let rowIdx = ed.buf.topLine + i
    if rowIdx >= ed.buf.lines.len: break
    let y = contentTop + cint(i) * gH
    let isCur = (rowIdx == ed.buf.cursorRow)
    let n =
      case config.lineNumbers
      of lnmOff:      0
      of lnmGlobal:   rowIdx + 1
      of lnmRelative:
        if isCur: rowIdx + 1
        else: abs(rowIdx - ed.buf.cursorRow)
    let s = $n
    let color = if isCur: ui.theme.text else: ui.theme.textDisabled
    let r = Rectangle(l: bx, r: bx + gutterW - gW,
                      t: y, b: y + gH)
    drawString(painter, r, s.cstring, s.len, color, cint(ALIGN_RIGHT), nil)

proc editorMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let ed = cast[ptr Editor](element)
  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    let (gW, gH) = glyphDims()
    drawBlock(painter, ed.e.bounds, ui.theme.codeBackground)
    paintTabStrip(ed, painter)
    let stripH = tabStripHeight()
    let bx = ed.e.bounds.l
    let by = ed.e.bounds.t + stripH
    let gutterW = gutterWidth(ed)
    let vr = visibleRows(ed)
    refreshStates(ed, ed.buf.topLine + vr)
    if gutterW > 0:
      paintGutter(ed, painter, by, gW, gH, vr, gutterW)
    let contentLeft = bx + gutterW
    for i in 0 ..< vr:
      let rowIdx = ed.buf.topLine + i
      if rowIdx >= ed.buf.lines.len: break
      let y = by + cint(i) * gH
      let rowRect = Rectangle(l: contentLeft, r: ed.e.bounds.r,
                              t: y, b: y + gH)
      let line = ed.buf.lines[rowIdx]
      if line.len > 0:
        let entry =
          if rowIdx < ed.buf.lineStartStates.len: ed.buf.lineStartStates[rowIdx]
          else: 0'u8
        highlight.paintLine(painter, rowRect, line, ed.buf.syntax,
                            entry, ed.buf.spans)
    # cursor
    let cRowOnScreen = ed.buf.cursorRow - ed.buf.topLine
    if cRowOnScreen >= 0 and cRowOnScreen < vr:
      let cx = contentLeft + cint(ed.buf.cursorCol) * gW
      let cy = by + cint(cRowOnScreen) * gH
      let mode = ed.buf.mode
      let focused = (element.window != nil and element.window.focused == element)
      if mode == cmInsert:
        drawInvert(painter, Rectangle(l: cx, r: cx + gW, t: cy, b: cy + gH))
      else:  # cmNormal — thin vertical line, blinks when focused
        if (not focused) or cursorBlinkOn:
          drawBlock(painter,
                    Rectangle(l: cx, r: cx + 2, t: cy, b: cy + gH),
                    ui.theme.text)
    # focus border
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, ed.e.bounds, 0x9253be'u32,
                 Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgLayout:
    clampCursor(ed)
    followCursor(ed)
    return 0

  elif message == msgLeftDown:
    elementFocus(element)
    let (gW, gH) = glyphDims()
    let w = element.window
    if w != nil:
      let lx = w.cursorX - ed.e.bounds.l
      let ly = w.cursorY - ed.e.bounds.t
      let stripH = tabStripHeight()
      if ly >= 0 and ly < stripH:
        let idx = tabAtX(ed, lx)
        if idx >= 0 and idx < ed.tabs.len:
          ed.activeIdx = idx
          elementRepaint(element, nil)
        return 1
      let gutterW = gutterWidth(ed)
      let contentLx = lx - gutterW
      let contentLy = ly - stripH
      if contentLx < 0 or contentLy < 0: return 1
      let row = ed.buf.topLine + int(contentLy div max(1, gH))
      let col = int(contentLx div max(1, gW))
      ed.buf.cursorRow = row
      ed.buf.cursorCol = col
      clampCursor(ed)
      followCursor(ed)
      elementRepaint(element, nil)
    return 1

  elif message == msgMouseWheel:
    let vr = visibleRows(ed)
    ed.buf.topLine += int(di) div 60
    if ed.buf.topLine < 0: ed.buf.topLine = 0
    let maxTop = max(0, ed.buf.lines.len - vr)
    if ed.buf.topLine > maxTop: ed.buf.topLine = maxTop
    elementRepaint(element, nil)
    return 1

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    let code = k.code
    let alt  = (w != nil and w.alt)
    let ctrl = (w != nil and w.ctrl)
    clampCursor(ed)

    if alt:
      let isDown = code == int(KEYCODE_LETTER('J')) or code == int(KEYCODE_DOWN)
      let isUp   = code == int(KEYCODE_LETTER('K')) or code == int(KEYCODE_UP)
      if isDown or isUp:
        let n = max(1, config.cursorJumpLines)
        if isDown: ed.buf.cursorRow += n
        else:      ed.buf.cursorRow -= n
        clampCursor(ed)
        followCursor(ed)
        elementRepaint(element, nil)
        return 1
      # Other Alt+... bubble up for pane navigation / window shortcuts.
      return 0

    if code == int(KEYCODE_INSERT):
      ed.buf.mode =
        if ed.buf.mode == cmInsert: cmNormal else: cmInsert
      elementRepaint(element, nil)
      return 1

    if ctrl:
      if code == int(KEYCODE_LETTER('F')):
        ed.buf.cursorCol += 1
      elif code == int(KEYCODE_LETTER('B')):
        ed.buf.cursorCol -= 1
      elif code == int(KEYCODE_LETTER('N')):
        ed.buf.cursorRow += 1
      elif code == int(KEYCODE_LETTER('P')):
        ed.buf.cursorRow -= 1
      elif code == int(KEYCODE_LETTER('A')):
        ed.buf.cursorCol = 0
      elif code == int(KEYCODE_LETTER('E')):
        ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
      elif code == int(KEYCODE_LETTER('K')):
        killToEnd(ed)
      elif code == int(KEYCODE_LETTER('S')):
        saveCurrent(ed)
      else:
        return 0
      clampCursor(ed)
      followCursor(ed)
      elementRepaint(element, nil)
      return 1

    if code == int(KEYCODE_LEFT):
      ed.buf.cursorCol -= 1
    elif code == int(KEYCODE_RIGHT):
      ed.buf.cursorCol += 1
    elif code == int(KEYCODE_UP):
      ed.buf.cursorRow -= 1
    elif code == int(KEYCODE_DOWN):
      ed.buf.cursorRow += 1
    elif code == int(KEYCODE_HOME):
      ed.buf.cursorCol = 0
    elif code == int(KEYCODE_END):
      ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
    elif code == int(KEYCODE_ENTER):
      insertNewline(ed)
    elif code == int(KEYCODE_BACKSPACE):
      backspace(ed)
    elif code == int(KEYCODE_TAB):
      insertText(ed, config.indentString())
    elif k.textBytes > 0:
      var s = newString(int(k.textBytes))
      copyMem(addr s[0], k.text, int(k.textBytes))
      insertText(ed, s)
    else:
      return 0

    clampCursor(ed)
    followCursor(ed)
    elementRepaint(element, nil)
    return 1

  return 0

proc editorCreate*(parent: ptr Element, flags: uint32 = 0): ptr Editor =
  let e = elementCreate(csize_t(sizeof(Editor)), parent, flags or ELEMENT_TAB_STOP,
                        editorMessage, "Editor")
  let ed = cast[ptr Editor](e)
  var scratch: EditorBuf
  loadIntoBuf(scratch, "")
  ed.tabs = @[scratch]
  ed.activeIdx = 0
  theEditor = ed
  return ed
