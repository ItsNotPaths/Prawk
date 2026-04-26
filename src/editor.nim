import std/[os, strutils]
import luigi, config, font, highlight, clipboard

type
  EditorBuf* = object
    lines: seq[string]
    cursorRow, cursorCol: int
    topLine: int
    topCol: int
    path: string
    dirty: bool
    mode: CursorMode
    syntax: ptr SyntaxRule
    lineStartStates: seq[uint8]   # 1 byte per line (tokenizer entry state)
    dirtyFromRow: int             # min row whose entry state may be stale
    spans: seq[Span]              # reused per-paint buffer
    selAnchorRow, selAnchorCol: int
    hasSel: bool
    panning: bool
    panStartX, panStartY: cint
    panStartTopLine, panStartTopCol: int
    wrap: bool

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

proc visibleCols(ed: ptr Editor): int =
  let (gW, _) = glyphDims()
  let avail = max(0, int(ed.e.bounds.r - ed.e.bounds.l - gutterWidth(ed)))
  max(1, avail div max(1, int(gW)))

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
  let vc = visibleCols(ed)
  if ed.buf.cursorCol < ed.buf.topCol:
    ed.buf.topCol = ed.buf.cursorCol
  elif ed.buf.cursorCol >= ed.buf.topCol + vc:
    ed.buf.topCol = ed.buf.cursorCol - vc + 1
  if ed.buf.topCol < 0: ed.buf.topCol = 0

proc editorWrapEnabled*(ed: ptr Editor): bool =
  ed != nil and ed.tabs.len > 0 and ed.tabs[ed.activeIdx].wrap

proc editorWrapToggle*(ed: ptr Editor) =
  if ed == nil or ed.tabs.len == 0: return
  ed.tabs[ed.activeIdx].wrap = not ed.tabs[ed.activeIdx].wrap
  if ed.tabs[ed.activeIdx].wrap:
    ed.tabs[ed.activeIdx].topCol = 0   # horizontal scroll meaningless when wrapped
  elementRepaint(addr ed.e, nil)

proc editorWrapToggleActive*() =
  editorWrapToggle(theEditor)

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
  b.topCol = 0
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

type VRow = tuple[rowIdx, lo, hi, segIdx: int, y: cint]

proc paintGutter(ed: ptr Editor, painter: ptr Painter,
                 contentTop: cint, gW, gH: cint, gutterW: cint,
                 vrows: seq[VRow]) =
  let bx = ed.e.bounds.l
  let gutterRect = Rectangle(l: bx, r: bx + gutterW,
                             t: contentTop, b: ed.e.bounds.b)
  drawBlock(painter, gutterRect, ui.theme.panel2)
  for vrow in vrows:
    # Continuation segments (segIdx > 0) leave the gutter slot blank — the
    # logical line's number only renders on its first visual row.
    if vrow.segIdx != 0: continue
    let rowIdx = vrow.rowIdx
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
                      t: vrow.y, b: vrow.y + gH)
    drawString(painter, r, s.cstring, s.len, color, cint(ALIGN_RIGHT), nil)

proc buildVisibleRows(ed: ptr Editor, by, gH: cint, vr, vc: int): seq[VRow] =
  ## Returns the logical-line slices that occupy each visible visual row.
  ## In wrap mode each long line breaks into ceil(len/vc) segments stacked
  ## vertically; in non-wrap mode each logical line gets one full-row entry.
  result = @[]
  var visualY: cint = by
  var rowIdx = ed.buf.topLine
  let wrapOn = ed.buf.wrap
  let n = ed.buf.lines.len
  while result.len < vr and rowIdx < n:
    let lineLen = ed.buf.lines[rowIdx].len
    if not wrapOn:
      result.add((rowIdx: rowIdx, lo: 0, hi: lineLen, segIdx: 0, y: visualY))
      visualY += gH
    else:
      let segs = max(1, (lineLen + vc - 1) div vc)
      for s in 0 ..< segs:
        if result.len >= vr: break
        let lo = s * vc
        let hi = min(lineLen, (s + 1) * vc)
        result.add((rowIdx: rowIdx, lo: lo, hi: hi, segIdx: s, y: visualY))
        visualY += gH
    inc rowIdx

proc clickToLogical(ed: ptr Editor, winX, winY: cint): tuple[row, col: int] =
  ## Translate a window-pixel click into a logical (row, col), accounting for
  ## both horizontal scroll and (when on) soft-wrap segmentation.
  let (gW, gH) = glyphDims()
  let bx = ed.e.bounds.l
  let by = ed.e.bounds.t
  let gutterW = gutterWidth(ed)
  let lx = winX - bx
  let ly = winY - by
  let contentLx = lx - gutterW
  if not ed.buf.wrap:
    let row = ed.buf.topLine + int(ly div max(cint(1), gH))
    let col = ed.buf.topCol + int(max(cint(0), contentLx) div max(cint(1), gW))
    return (row, col)
  let vr = visibleRows(ed)
  let vc = visibleCols(ed)
  let vrows = buildVisibleRows(ed, by, gH, vr, vc)
  if vrows.len == 0:
    return (ed.buf.topLine, 0)
  var visIdx = int(max(cint(0), ly) div max(cint(1), gH))
  if visIdx >= vrows.len: visIdx = vrows.len - 1
  let vrow = vrows[visIdx]
  let cellOff = vrow.lo
  let withinSeg = int(max(cint(0), contentLx) div max(cint(1), gW))
  let col = clamp(cellOff + withinSeg, vrow.lo, vrow.hi)
  (vrow.rowIdx, col)

proc cursorVRowIdx(ed: ptr Editor, vrows: seq[VRow]): int =
  ## Index in vrows of the visual row holding the cursor; -1 if off-screen.
  for i, vr in vrows:
    if vr.rowIdx != ed.buf.cursorRow: continue
    if not ed.buf.wrap:
      return i
    # Wrap mode: slice contains cursorCol (with the end-of-line edge case
    # — col == lineLen lands on the last segment).
    if (ed.buf.cursorCol >= vr.lo and ed.buf.cursorCol < vr.hi) or
       (ed.buf.cursorCol == vr.hi and
        (i + 1 >= vrows.len or vrows[i + 1].rowIdx != ed.buf.cursorRow)):
      return i
  -1

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
    let vc = visibleCols(ed)
    refreshStates(ed, ed.buf.topLine + vr)
    let topColOff = if ed.buf.wrap: 0 else: ed.buf.topCol
    let contentLeft0 = bx + gutterW - cint(topColOff) * gW
    let contentBaseLeft = bx + gutterW
    var selSR, selSC, selER, selEC: int
    if ed.buf.hasSel:
      (selSR, selSC, selER, selEC) = selOrdered(ed)
    let vrows = buildVisibleRows(ed, by, gH, vr, vc)
    for vrow in vrows:
      let rowIdx = vrow.rowIdx
      let y = vrow.y
      let line = ed.buf.lines[rowIdx]
      let leftX = if ed.buf.wrap: contentBaseLeft else: contentLeft0
      let rowRect = Rectangle(l: leftX, r: ed.e.bounds.r,
                              t: y, b: y + gH)
      # selection band — drawn under tokens so glyphs stay readable.
      if ed.buf.hasSel and rowIdx >= selSR and rowIdx <= selER:
        let rowLo =
          if rowIdx == selSR: selSC else: 0
        let rowHi =
          if rowIdx == selER: selEC
          elif rowIdx < selER: line.len + 1
          else: 0
        # Clip selection range to this visual segment when wrapped.
        let segLo = if ed.buf.wrap: max(rowLo, vrow.lo) else: rowLo
        let segHi = if ed.buf.wrap: min(rowHi, vrow.hi + (if rowIdx < selER and vrow.hi == line.len: 1 else: 0)) else: rowHi
        if segHi > segLo:
          let cellOff = if ed.buf.wrap: vrow.lo else: 0
          let x0 = leftX + cint(segLo - cellOff) * gW
          let x1 = leftX + cint(segHi - cellOff) * gW
          drawBlock(painter, Rectangle(l: x0, r: x1, t: y, b: y + gH),
                    ui.theme.selected)
      if line.len > 0:
        let entry =
          if rowIdx < ed.buf.lineStartStates.len: ed.buf.lineStartStates[rowIdx]
          else: 0'u8
        if ed.buf.wrap:
          # Substring per visual segment. Walk the prefix to compute the
          # segment-entry tokenizer state on the fly.
          var st = entry
          var col = 0
          while col < vrow.lo and col < line.len:
            let chunk = line[col ..< min(line.len, vrow.lo)]
            st = highlight.advanceState(chunk, ed.buf.syntax, st)
            col = vrow.lo
          if vrow.hi > vrow.lo:
            let slice = line[vrow.lo ..< vrow.hi]
            highlight.paintLine(painter, rowRect, slice, ed.buf.syntax,
                                st, ed.buf.spans)
        else:
          highlight.paintLine(painter, rowRect, line, ed.buf.syntax,
                              entry, ed.buf.spans)
    # cursor
    let cVI = cursorVRowIdx(ed, vrows)
    if cVI >= 0:
      let vrow = vrows[cVI]
      let leftX = if ed.buf.wrap: contentBaseLeft else: contentLeft0
      let cellOff = if ed.buf.wrap: vrow.lo else: 0
      let cx = leftX + cint(ed.buf.cursorCol - cellOff) * gW
      let cy = vrow.y
      let mode = ed.buf.mode
      let focused = (element.window != nil and element.window.focused == element)
      if mode == cmInsert:
        drawInvert(painter, Rectangle(l: cx, r: cx + gW, t: cy, b: cy + gH))
      else:
        if (not focused) or cursorBlinkOn:
          drawBlock(painter,
                    Rectangle(l: cx, r: cx + 2, t: cy, b: cy + gH),
                    ui.theme.text)
    # Gutter painted last so any leftward bleed from horizontal scroll
    # (tokens / selection rects with x < gutterRight) gets covered cleanly.
    # Driven by vrows so wrap continuations get blank gutter slots and the
    # current-line highlight tracks the actual logical cursor row.
    if gutterW > 0:
      paintGutter(ed, painter, by, gW, gH, gutterW, vrows)
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
    ed.buf.panning = false
    let w = element.window
    if w != nil:
      let (row, col) = clickToLogical(ed, w.cursorX, w.cursorY)
      ed.buf.cursorRow = row
      ed.buf.cursorCol = col
      clampCursor(ed)
      followCursor(ed)
      ed.buf.selAnchorRow = ed.buf.cursorRow
      ed.buf.selAnchorCol = ed.buf.cursorCol
      ed.buf.hasSel = false
      elementRepaint(element, nil)
    return 1

  elif message == msgMiddleDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      ed.buf.panning = true
      ed.buf.panStartX = w.cursorX
      ed.buf.panStartY = w.cursorY
      ed.buf.panStartTopLine = ed.buf.topLine
      ed.buf.panStartTopCol = ed.buf.topCol
    return 1

  elif message == msgMiddleUp:
    ed.buf.panning = false
    return 1

  elif message == msgMouseDrag:
    let (gW, gH) = glyphDims()
    let w = element.window
    if w == nil: return 1
    if ed.buf.panning:
      # Grab-the-document semantics: drag the text with the mouse, so view
      # scrolls opposite to drag direction.
      let dx = w.cursorX - ed.buf.panStartX
      let dy = w.cursorY - ed.buf.panStartY
      let newTopLine = ed.buf.panStartTopLine - int(dy) div max(1, int(gH))
      let newTopCol  = ed.buf.panStartTopCol  - int(dx) div max(1, int(gW))
      let vr = visibleRows(ed)
      let maxTop = max(0, ed.buf.lines.len - vr)
      ed.buf.topLine = max(0, min(maxTop, newTopLine))
      ed.buf.topCol  = max(0, newTopCol)
      elementRepaint(element, nil)
      return 1
    let (row, col) = clickToLogical(ed, w.cursorX, w.cursorY)
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
