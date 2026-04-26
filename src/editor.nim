import std/[os, strutils]
import luigi, config, font, highlight, clipboard

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
    selAnchorRow, selAnchorCol: int
    hasSel: bool

  Editor* = object
    e*: Element
    tabs*: seq[EditorBuf]
    activeIdx*: int

var
  theEditor*: ptr Editor
  cursorBlinkOn*: bool = true
  editorAltUpCb*: proc() {.closure.}   # set by editortabs.nim

template buf(ed: ptr Editor): var EditorBuf = ed.tabs[ed.activeIdx]

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
  let avail = max(0, int(ed.e.bounds.b - ed.e.bounds.t))
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

proc selOrdered(ed: ptr Editor): tuple[sr, sc, er, ec: int] =
  ## Returns selection in document order (anchor and cursor swapped if needed).
  let aR = ed.buf.selAnchorRow
  let aC = ed.buf.selAnchorCol
  let cR = ed.buf.cursorRow
  let cC = ed.buf.cursorCol
  if (aR < cR) or (aR == cR and aC <= cC):
    (aR, aC, cR, cC)
  else:
    (cR, cC, aR, aC)

proc selCopyText(ed: ptr Editor): string =
  if not ed.buf.hasSel: return ""
  let (sR, sC, eR, eC) = selOrdered(ed)
  if sR == eR:
    let line = ed.buf.lines[sR]
    let lo = max(0, min(sC, line.len))
    let hi = max(lo, min(eC, line.len))
    return line.substr(lo, hi - 1)
  var parts: seq[string] = @[]
  let first = ed.buf.lines[sR]
  parts.add(first.substr(min(sC, first.len)))
  for r in (sR + 1) ..< eR:
    parts.add(ed.buf.lines[r])
  let last = ed.buf.lines[eR]
  parts.add(last.substr(0, min(eC, last.len) - 1))
  parts.join("\n")

proc deleteSelection(ed: ptr Editor) =
  if not ed.buf.hasSel: return
  let (sR, sC, eR, eC) = selOrdered(ed)
  let firstLine = ed.buf.lines[sR]
  let lastLine = ed.buf.lines[eR]
  let head = if sC <= 0: "" else: firstLine.substr(0, sC - 1)
  let tail = if eC >= lastLine.len: "" else: lastLine.substr(eC)
  ed.buf.lines[sR] = head & tail
  for _ in (sR + 1) .. eR:
    ed.buf.lines.delete(sR + 1)
  ed.buf.cursorRow = sR
  ed.buf.cursorCol = sC
  ed.buf.hasSel = false
  ed.buf.dirty = true
  invalidateFrom(ed, sR)

proc selAll(ed: ptr Editor) =
  if ed.buf.lines.len == 0: return
  ed.buf.selAnchorRow = 0
  ed.buf.selAnchorCol = 0
  ed.buf.cursorRow = ed.buf.lines.len - 1
  ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
  ed.buf.hasSel = true

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

proc isWS(c: char): bool {.inline.} =
  c == ' ' or c == '\t'

proc wordForward(ed: ptr Editor) =
  ## Vim-W-like jump: skip current run (whitespace or non-whitespace), then
  ## land on the start of the next non-whitespace block. Wraps to next line.
  var row = ed.buf.cursorRow
  var col = ed.buf.cursorCol
  if row >= ed.buf.lines.len: return
  var line = ed.buf.lines[row]
  if col >= line.len:
    if row + 1 < ed.buf.lines.len:
      ed.buf.cursorRow = row + 1
      ed.buf.cursorCol = 0
    return
  let inWS = isWS(line[col])
  while col < line.len and isWS(line[col]) == inWS: inc col
  while col < line.len and isWS(line[col]): inc col
  if col >= line.len and row + 1 < ed.buf.lines.len:
    ed.buf.cursorRow = row + 1
    ed.buf.cursorCol = 0
  else:
    ed.buf.cursorCol = col

proc wordBack(ed: ptr Editor) =
  ## Mirror of wordForward — land on the start of the previous word, wrapping
  ## to the end of the previous line when at column 0.
  var row = ed.buf.cursorRow
  var col = ed.buf.cursorCol
  if col == 0:
    if row > 0:
      ed.buf.cursorRow = row - 1
      ed.buf.cursorCol = ed.buf.lines[row - 1].len
    return
  let line = ed.buf.lines[row]
  dec col
  while col > 0 and isWS(line[col]): dec col
  while col > 0 and not isWS(line[col - 1]): dec col
  ed.buf.cursorCol = col

proc pageDown(ed: ptr Editor) =
  let vr = visibleRows(ed)
  ed.buf.cursorRow += vr
  ed.buf.topLine += vr

proc pageUp(ed: ptr Editor) =
  let vr = visibleRows(ed)
  ed.buf.cursorRow -= vr
  ed.buf.topLine -= vr

proc bufferStart(ed: ptr Editor) =
  ed.buf.cursorRow = 0
  ed.buf.cursorCol = 0

proc bufferEnd(ed: ptr Editor) =
  if ed.buf.lines.len == 0: return
  ed.buf.cursorRow = ed.buf.lines.len - 1
  ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len

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

proc editorTabLabel*(ed: ptr Editor, idx: int): string =
  if ed == nil or idx < 0 or idx >= ed.tabs.len: return ""
  let b = ed.tabs[idx]
  let nm = if b.path.len == 0: "[scratch]" else: extractFilename(b.path)
  if b.dirty: "* " & nm else: nm

proc editorTabSwitch*(ed: ptr Editor, idx: int) =
  if ed == nil or idx < 0 or idx >= ed.tabs.len: return
  ed.activeIdx = idx
  elementRepaint(addr ed.e, nil)

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
    let bx = ed.e.bounds.l
    let by = ed.e.bounds.t
    let gutterW = gutterWidth(ed)
    let vr = visibleRows(ed)
    refreshStates(ed, ed.buf.topLine + vr)
    if gutterW > 0:
      paintGutter(ed, painter, by, gW, gH, vr, gutterW)
    let contentLeft = bx + gutterW
    var selSR, selSC, selER, selEC: int
    if ed.buf.hasSel:
      (selSR, selSC, selER, selEC) = selOrdered(ed)
    for i in 0 ..< vr:
      let rowIdx = ed.buf.topLine + i
      if rowIdx >= ed.buf.lines.len: break
      let y = by + cint(i) * gH
      let rowRect = Rectangle(l: contentLeft, r: ed.e.bounds.r,
                              t: y, b: y + gH)
      let line = ed.buf.lines[rowIdx]
      # selection band — drawn under the tokens so the text remains readable.
      if ed.buf.hasSel and rowIdx >= selSR and rowIdx <= selER:
        let lo =
          if rowIdx == selSR: selSC else: 0
        let hi =
          if rowIdx == selER: selEC
          elif rowIdx < selER: line.len + 1   # +1 = cosmetic trailing cell so multi-line selections show the newline
          else: 0
        let x0 = contentLeft + cint(lo) * gW
        let x1 = contentLeft + cint(hi) * gW
        if x1 > x0:
          drawBlock(painter, Rectangle(l: x0, r: x1, t: y, b: y + gH),
                    ui.theme.selected)
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

  elif message == msgUpdate:
    # Focus / hover / pressed transitions need a repaint so the focus border
    # clears when focus moves to the tab pane (or anywhere else).
    elementRepaint(element, nil)
    return 0

  elif message == msgLeftDown:
    elementFocus(element)
    let (gW, gH) = glyphDims()
    let w = element.window
    if w != nil:
      let lx = w.cursorX - ed.e.bounds.l
      let ly = w.cursorY - ed.e.bounds.t
      let gutterW = gutterWidth(ed)
      let contentLx = lx - gutterW
      if contentLx < 0 or ly < 0: return 1
      let row = ed.buf.topLine + int(ly div max(1, gH))
      let col = int(contentLx div max(1, gW))
      ed.buf.cursorRow = row
      ed.buf.cursorCol = col
      clampCursor(ed)
      followCursor(ed)
      ed.buf.selAnchorRow = ed.buf.cursorRow
      ed.buf.selAnchorCol = ed.buf.cursorCol
      ed.buf.hasSel = false
      elementRepaint(element, nil)
    return 1

  elif message == msgMouseDrag:
    let (gW, gH) = glyphDims()
    let w = element.window
    if w != nil:
      let lx = w.cursorX - ed.e.bounds.l
      let ly = w.cursorY - ed.e.bounds.t
      let gutterW = gutterWidth(ed)
      let contentLx = lx - gutterW
      let row = ed.buf.topLine + int(ly div max(1, gH))
      let col = int(max(0, contentLx) div max(1, gW))
      ed.buf.cursorRow = row
      ed.buf.cursorCol = col
      clampCursor(ed)
      followCursor(ed)
      ed.buf.hasSel = (ed.buf.cursorRow != ed.buf.selAnchorRow or
                      ed.buf.cursorCol != ed.buf.selAnchorCol)
      if ed.buf.hasSel:
        clipboardSetPrimary(selCopyText(ed))
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
    let alt   = (w != nil and w.alt)
    let ctrl  = (w != nil and w.ctrl)
    let shift = (w != nil and w.shift)
    clampCursor(ed)

    let preRow = ed.buf.cursorRow
    let preCol = ed.buf.cursorCol

    template motionStart() =
      if shift:
        if not ed.buf.hasSel:
          ed.buf.selAnchorRow = preRow
          ed.buf.selAnchorCol = preCol
          ed.buf.hasSel = true
      else:
        ed.buf.hasSel = false

    template motionEnd() =
      if ed.buf.hasSel and
         ed.buf.selAnchorRow == ed.buf.cursorRow and
         ed.buf.selAnchorCol == ed.buf.cursorCol:
        ed.buf.hasSel = false
      if ed.buf.hasSel:
        clipboardSetPrimary(selCopyText(ed))

    template editStart() =
      if ed.buf.hasSel: deleteSelection(ed)

    if alt and shift:
      # Shift+Alt motion family — word/page/buffer. Shift here doubles for
      # both the Alt-modifier signal AND selection-extend (consistent with
      # plain Shift+arrow elsewhere).
      let oldHas = ed.buf.hasSel
      if not oldHas:
        ed.buf.selAnchorRow = preRow
        ed.buf.selAnchorCol = preCol
        ed.buf.hasSel = true
      if code == int(KEYCODE_LETTER('L')) or code == int(KEYCODE_RIGHT):
        wordForward(ed)
      elif code == int(KEYCODE_LETTER('H')) or code == int(KEYCODE_LEFT):
        wordBack(ed)
      elif code == int(KEYCODE_LETTER('J')) or code == int(KEYCODE_DOWN):
        pageDown(ed)
      elif code == int(KEYCODE_LETTER('K')) or code == int(KEYCODE_UP):
        pageUp(ed)
      elif code == int(KEYCODE_LETTER('A')) or code == int(KEYCODE_HOME):
        bufferStart(ed)
      elif code == int(KEYCODE_LETTER('E')) or code == int(KEYCODE_END):
        bufferEnd(ed)
      else:
        # Not a motion — restore the pre-call selection state and bubble.
        ed.buf.hasSel = oldHas
        return 0    # bubble — leaves Shift+Alt+T / Shift+Alt+P shortcuts alone
      clampCursor(ed)
      followCursor(ed)
      motionEnd()
      elementRepaint(element, nil)
      return 1

    if alt:
      # Alt+Up jumps focus to the tab pane above the editor.
      if code == int(KEYCODE_UP):
        if editorAltUpCb != nil: editorAltUpCb()
        return 1
      # Alt+J / Alt+K still jump N lines; arrow aliases dropped so that the
      # vertical-arrow grammar belongs to pane focus, not buffer motion.
      let isDown = code == int(KEYCODE_LETTER('J'))
      let isUp   = code == int(KEYCODE_LETTER('K'))
      if isDown or isUp:
        motionStart()
        let n = max(1, config.cursorJumpLines)
        if isDown: ed.buf.cursorRow += n
        else:      ed.buf.cursorRow -= n
        clampCursor(ed)
        followCursor(ed)
        motionEnd()
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
        motionStart(); ed.buf.cursorCol += 1
      elif code == int(KEYCODE_LETTER('B')):
        motionStart(); ed.buf.cursorCol -= 1
      elif code == int(KEYCODE_LETTER('N')):
        motionStart(); ed.buf.cursorRow += 1
      elif code == int(KEYCODE_LETTER('P')):
        motionStart(); ed.buf.cursorRow -= 1
      elif code == int(KEYCODE_LETTER('A')):
        if shift:
          selAll(ed)
        else:
          motionStart(); ed.buf.cursorCol = 0
      elif code == int(KEYCODE_LETTER('E')):
        motionStart(); ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
      elif code == int(KEYCODE_LETTER('K')):
        editStart(); killToEnd(ed)
      elif code == int(KEYCODE_LETTER('S')):
        saveCurrent(ed)
      elif code == int(KEYCODE_LETTER('C')):
        if ed.buf.hasSel: clipboardSetBoth(selCopyText(ed))
      elif code == int(KEYCODE_LETTER('V')):
        editStart()
        let txt = clipboardGet()
        if txt.len > 0:
          let parts = txt.splitLines()
          for i, line in parts:
            if i > 0: insertNewline(ed)
            if line.len > 0: insertText(ed, line)
      else:
        return 0
      # K/S/C/V are not motions — skip the motionEnd finalize. selAll
      # already set hasSel; motionEnd just publishes to PRIMARY.
      if not (code == int(KEYCODE_LETTER('K')) or
              code == int(KEYCODE_LETTER('S')) or
              code == int(KEYCODE_LETTER('C')) or
              code == int(KEYCODE_LETTER('V'))):
        motionEnd()
      clampCursor(ed)
      followCursor(ed)
      elementRepaint(element, nil)
      return 1

    if code == int(KEYCODE_LEFT):
      motionStart(); ed.buf.cursorCol -= 1; motionEnd()
    elif code == int(KEYCODE_RIGHT):
      motionStart(); ed.buf.cursorCol += 1; motionEnd()
    elif code == int(KEYCODE_UP):
      motionStart(); ed.buf.cursorRow -= 1; motionEnd()
    elif code == int(KEYCODE_DOWN):
      motionStart(); ed.buf.cursorRow += 1; motionEnd()
    elif code == int(KEYCODE_HOME):
      motionStart(); ed.buf.cursorCol = 0; motionEnd()
    elif code == int(KEYCODE_END):
      motionStart(); ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
      motionEnd()
    elif code == int(KEYCODE_ENTER):
      editStart(); insertNewline(ed)
    elif code == int(KEYCODE_BACKSPACE):
      if ed.buf.hasSel: deleteSelection(ed)
      else: backspace(ed)
    elif code == int(KEYCODE_TAB):
      editStart(); insertText(ed, config.indentString())
    elif k.textBytes > 0:
      editStart()
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
