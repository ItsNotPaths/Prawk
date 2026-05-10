import std/[os, strutils, algorithm]
import luigi, config, font, highlight, clipboard, theme

type
  EditKind = enum
    ekNone, ekInsert, ekBackspace, ekOther

  ExtraCursor* = object
    row*, col*: int

  Snapshot = object
    lines: seq[string]
    cursorRow, cursorCol: int
    selAnchorRow, selAnchorCol: int
    hasSel: bool

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
    extraCursors: seq[ExtraCursor]   # secondary insertion points (Alt+click)
    panning: bool
    panStartX, panStartY: cint
    panStartTopLine, panStartTopCol: int
    wrap: bool
    undoStack: seq[Snapshot]
    redoStack: seq[Snapshot]
    lastEditKind: EditKind
    lastEditRow, lastEditCol: int   # cursor position after the last edit

  Editor* = object
    e*: Element
    tabs*: seq[EditorBuf]
    activeIdx*: int

var
  theEditor*: ptr Editor
  cursorBlinkOn*: bool = true
  editorAltUpCb*: proc() {.closure.}   # set by editortabs.nim
  editorTabsRepaintCb*: proc() {.closure.}   # set by editortabs.nim

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
  let was = ed.buf.dirty
  ed.buf.dirty = true
  if not was and editorTabsRepaintCb != nil: editorTabsRepaintCb()
  invalidateFrom(ed, sR)

proc selAll(ed: ptr Editor) =
  if ed.buf.lines.len == 0: return
  ed.buf.extraCursors.setLen(0)
  ed.buf.selAnchorRow = 0
  ed.buf.selAnchorCol = 0
  ed.buf.cursorRow = ed.buf.lines.len - 1
  ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
  ed.buf.hasSel = true

proc markDirty(ed: ptr Editor)   # forward decl — defined later
# --- multi-cursor helpers ----------------------------------------------------
# Extra cursors are pure insertion points (no per-cursor selections). All
# editing ops apply to primary + extras; undo collapses back to a single
# cursor. Selection (hasSel) is owned by the primary only.

proc clearExtraCursors*(ed: ptr Editor) =
  if ed != nil and ed.buf.extraCursors.len > 0:
    ed.buf.extraCursors.setLen(0)

proc lineColToOffset(lines: seq[string], r, c: int): int =
  var off = 0
  let rr = clamp(r, 0, max(0, lines.len - 1))
  for i in 0 ..< rr: off += lines[i].len + 1
  off + clamp(c, 0, lines[rr].len)

proc offsetToLineCol(lines: seq[string], off: int): (int, int) =
  var rem = max(0, off)
  for i, ln in lines:
    if rem <= ln.len: return (i, rem)
    rem -= ln.len + 1
  let last = max(0, lines.len - 1)
  (last, if lines.len > 0: lines[last].len else: 0)

proc gatherCursorOffsets(b: EditorBuf): seq[int] =
  result = newSeq[int](1 + b.extraCursors.len)
  result[0] = lineColToOffset(b.lines, b.cursorRow, b.cursorCol)
  for i, ec in b.extraCursors:
    result[i + 1] = lineColToOffset(b.lines, ec.row, ec.col)

proc dedupeAndScatter(ed: ptr Editor, offs: seq[int]) =
  ## Write offsets back to primary + extras. Drops duplicates so two cursors
  ## that end up at the same spot collapse into one.
  var seen: seq[int] = @[]
  for o in offs:
    var dup = false
    for s in seen:
      if s == o: dup = true; break
    if not dup: seen.add(o)
  if seen.len == 0: seen.add(0)
  let pri = offsetToLineCol(ed.buf.lines, seen[0])
  ed.buf.cursorRow = pri[0]
  ed.buf.cursorCol = pri[1]
  ed.buf.extraCursors.setLen(0)
  for i in 1 ..< seen.len:
    let (r, c) = offsetToLineCol(ed.buf.lines, seen[i])
    ed.buf.extraCursors.add(ExtraCursor(row: r, col: c))

proc applyMultiEdit(ed: ptr Editor,
                    perOffset: proc(flat: var string, off: int): int) =
  ## Apply an edit at every cursor. `perOffset` mutates `flat` at the given
  ## offset and returns the new offset for that cursor (e.g., off+s.len for an
  ## insert, off-1 for a backspace). Edits are applied in ascending offset
  ## order; remaining cursors are shifted by the running delta so each fires
  ## at the right spot in the now-mutated buffer.
  let origOffs = gatherCursorOffsets(ed.buf)
  var indexed = newSeq[(int, int)](origOffs.len)
  for i, o in origOffs: indexed[i] = (o, i)
  indexed.sort(proc(a, b: (int, int)): int = a[0] - b[0])
  var flat = ed.buf.lines.join("\n")
  var newOffs = newSeq[int](origOffs.len)
  var delta = 0
  for (o, oi) in indexed:
    let realO = o + delta
    let preLen = flat.len
    newOffs[oi] = perOffset(flat, realO)
    delta += flat.len - preLen
  ed.buf.lines = flat.split('\n')
  if ed.buf.lines.len == 0: ed.buf.lines.add("")
  dedupeAndScatter(ed, newOffs)
  ed.buf.dirtyFromRow = 0
  ed.buf.lineStartStates.setLen(0)

proc multiInsertText*(ed: ptr Editor, s: string) =
  if s.len == 0: return
  if ed.buf.extraCursors.len == 0:
    # Fast path: single-cursor inline edit, no flat-buffer round-trip.
    let row = ed.buf.cursorRow
    let col = ed.buf.cursorCol
    let line = ed.buf.lines[row]
    let pieces = s.split('\n')
    if pieces.len == 1:
      ed.buf.lines[row] = line.substr(0, col - 1) & s & line.substr(col)
      ed.buf.cursorCol = col + s.len
    else:
      ed.buf.lines[row] = line.substr(0, col - 1) & pieces[0]
      for i in 1 ..< pieces.len:
        ed.buf.lines.insert(pieces[i], row + i)
      ed.buf.lines[row + pieces.high] =
        ed.buf.lines[row + pieces.high] & line.substr(col)
      ed.buf.cursorRow = row + pieces.high
      ed.buf.cursorCol = pieces[^1].len
    invalidateFrom(ed, row)
    markDirty(ed)
    return
  applyMultiEdit(ed, proc(flat: var string, off: int): int =
    flat = flat.substr(0, off - 1) & s & flat.substr(off)
    off + s.len)
  markDirty(ed)

proc multiBackspace*(ed: ptr Editor) =
  if ed.buf.extraCursors.len == 0:
    return  # caller falls back to single-cursor backspace
  applyMultiEdit(ed, proc(flat: var string, off: int): int =
    if off <= 0: return 0
    flat = flat.substr(0, off - 2) & flat.substr(off)
    off - 1)
  markDirty(ed)

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
  b.undoStack.setLen(0)
  b.redoStack.setLen(0)
  b.lastEditKind = ekNone
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
    if path.len > 0 and not path.startsWith("diff://"):
      config.pushRecent("recents.files", path)
    elementRepaint(addr ed.e, nil)
    if editorTabsRepaintCb != nil: editorTabsRepaintCb()
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
  if path.len > 0 and not path.startsWith("diff://"):
    config.pushRecent("recents.files", path)
  elementRepaint(addr ed.e, nil)
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc editorOpenSynthetic*(ed: ptr Editor, synthPath, content: string) =
  ## Opens a non-disk buffer (e.g. a git diff). `synthPath` is used as the
  ## tab's identity for dedupe; saving is a no-op for paths starting with
  ## `diff://` (handled by saveCurrent). The buffer is fully editable in
  ## memory — edits just don't persist anywhere.
  if ed == nil: return
  let existing = findTab(ed, synthPath)
  if existing >= 0:
    ed.activeIdx = existing
    elementRepaint(addr ed.e, nil)
    if editorTabsRepaintCb != nil: editorTabsRepaintCb()
    return
  proc fillBuf(b: var EditorBuf, p, body: string) =
    b.path = p
    b.lines = body.splitLines()
    if b.lines.len == 0: b.lines.add("")
    b.cursorRow = 0; b.cursorCol = 0
    b.topLine = 0; b.topCol = 0
    b.dirty = false
    b.mode = config.cursorMode
    b.syntax = highlight.syntaxByName("diff")
    b.lineStartStates.setLen(0)
    b.dirtyFromRow = 0
  var nb: EditorBuf
  fillBuf(nb, synthPath, content)
  ed.tabs.add(nb)
  ed.activeIdx = ed.tabs.len - 1
  elementRepaint(addr ed.e, nil)
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

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
  # Tabs strip is a separate widget — needs its own repaint so the closed
  # label disappears immediately. Without this the strip stays stale until
  # something else (focus change, hover) triggers it.
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc editorTabNext*(ed: ptr Editor) =
  if ed == nil or ed.tabs.len <= 1: return
  ed.activeIdx = (ed.activeIdx + 1) mod ed.tabs.len
  elementRepaint(addr ed.e, nil)
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc editorTabPrev*(ed: ptr Editor) =
  if ed == nil or ed.tabs.len <= 1: return
  ed.activeIdx = (ed.activeIdx - 1 + ed.tabs.len) mod ed.tabs.len
  elementRepaint(addr ed.e, nil)
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc editorTabMove*(ed: ptr Editor, dir: int) =
  ## Move the active tab by `dir` positions (negative = leftward). Wraps.
  if ed == nil or ed.tabs.len <= 1 or dir == 0: return
  let n = ed.tabs.len
  let cur = ed.activeIdx
  let dst = ((cur + dir) mod n + n) mod n
  if dst == cur: return
  swap(ed.tabs[cur], ed.tabs[dst])
  ed.activeIdx = dst
  elementRepaint(addr ed.e, nil)
  if editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc markDirty(ed: ptr Editor) =
  let was = ed.buf.dirty
  ed.buf.dirty = true
  if not was and editorTabsRepaintCb != nil:
    editorTabsRepaintCb()

const undoCap = 500

proc takeSnapshot(b: EditorBuf): Snapshot =
  Snapshot(lines: b.lines, cursorRow: b.cursorRow, cursorCol: b.cursorCol,
           selAnchorRow: b.selAnchorRow, selAnchorCol: b.selAnchorCol,
           hasSel: b.hasSel)

proc applySnapshot(b: var EditorBuf, s: Snapshot) =
  b.lines = s.lines
  b.cursorRow = s.cursorRow
  b.cursorCol = s.cursorCol
  b.selAnchorRow = s.selAnchorRow
  b.selAnchorCol = s.selAnchorCol
  b.hasSel = s.hasSel
  b.extraCursors.setLen(0)   # snapshots don't carry multi-cursor state
  b.dirtyFromRow = 0   # rehighlight from top after a structural change
  b.lineStartStates.setLen(0)

proc pushUndo(ed: ptr Editor, kind: EditKind) =
  ## Snapshot before mutating. Coalesces consecutive same-kind edits at the
  ## position the previous edit ended on, so a typing run becomes one undo
  ## step rather than one per keystroke.
  let coalesce = kind != ekOther and
                 kind == ed.buf.lastEditKind and
                 ed.buf.cursorRow == ed.buf.lastEditRow and
                 ed.buf.cursorCol == ed.buf.lastEditCol
  if not coalesce:
    if ed.buf.undoStack.len >= undoCap:
      ed.buf.undoStack.delete(0)
    ed.buf.undoStack.add(takeSnapshot(ed.buf))
  ed.buf.redoStack.setLen(0)
  ed.buf.lastEditKind = kind

proc noteEditEnd(ed: ptr Editor) =
  ## Call after each edit so coalescing can compare the next edit's starting
  ## cursor against where the previous edit left off.
  ed.buf.lastEditRow = ed.buf.cursorRow
  ed.buf.lastEditCol = ed.buf.cursorCol

proc editorUndo*(ed: ptr Editor) =
  if ed == nil or ed.buf.undoStack.len == 0: return
  ed.buf.redoStack.add(takeSnapshot(ed.buf))
  let s = ed.buf.undoStack.pop()
  applySnapshot(ed.buf, s)
  ed.buf.lastEditKind = ekNone
  markDirty(ed)
  clampCursor(ed)
  followCursor(ed)
  elementRepaint(addr ed.e, nil)

proc editorRedo*(ed: ptr Editor) =
  if ed == nil or ed.buf.redoStack.len == 0: return
  ed.buf.undoStack.add(takeSnapshot(ed.buf))
  let s = ed.buf.redoStack.pop()
  applySnapshot(ed.buf, s)
  ed.buf.lastEditKind = ekNone
  markDirty(ed)
  clampCursor(ed)
  followCursor(ed)
  elementRepaint(addr ed.e, nil)

proc editorCopySelection*(ed: ptr Editor) =
  if ed == nil or not ed.buf.hasSel: return
  clipboardSetBoth(selCopyText(ed))

proc insertText(ed: ptr Editor, s: string) =
  if s.len == 0: return
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1) & s & line.substr(col)
  ed.buf.cursorCol = col + s.len
  markDirty(ed)
  invalidateFrom(ed, row)

proc insertNewline(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1)
  ed.buf.lines.insert(line.substr(col), row + 1)
  ed.buf.cursorRow = row + 1
  ed.buf.cursorCol = 0
  markDirty(ed)
  invalidateFrom(ed, row)

proc backspace(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  if col > 0:
    let line = ed.buf.lines[row]
    ed.buf.lines[row] = line.substr(0, col - 2) & line.substr(col)
    ed.buf.cursorCol = col - 1
    markDirty(ed)
    invalidateFrom(ed, row)
  elif row > 0:
    let prev = ed.buf.lines[row - 1]
    let cur = ed.buf.lines[row]
    ed.buf.cursorCol = prev.len
    ed.buf.lines[row - 1] = prev & cur
    ed.buf.lines.delete(row)
    ed.buf.cursorRow = row - 1
    markDirty(ed)
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

proc dimToward(fg, bg: uint32, alpha: float): uint32 {.inline.} =
  let inv = 1.0 - alpha
  let fr = int((fg shr 16) and 0xFF); let br = int((bg shr 16) and 0xFF)
  let fG = int((fg shr 8)  and 0xFF); let bG = int((bg shr 8)  and 0xFF)
  let fB = int(fg and 0xFF);          let bB = int(bg and 0xFF)
  let nr = int(float(fr) * alpha + float(br) * inv)
  let ng = int(float(fG) * alpha + float(bG) * inv)
  let nb = int(float(fB) * alpha + float(bB) * inv)
  uint32((nr shl 16) or (ng shl 8) or nb)

proc drawDot(painter: ptr Painter, cx, cy: cint, w, h: cint, color: uint32) =
  ## Direct-pixel dot — sidesteps the font (no glyph for U+00B7 in our
  ## embedded font, so drawString fell back to '?'). Same trick the minimap
  ## uses: write straight into painter.bits, clipped against painter.clip.
  let fb = painterPixels(painter)
  let stride = int(painter.width)
  let clip = painter.clip
  for dy in 0 ..< int(h):
    let py = int(cy) + dy
    if py < int(clip.t) or py >= int(clip.b): continue
    let rowOff = py * stride
    for dx in 0 ..< int(w):
      let px = int(cx) + dx
      if px < int(clip.l) or px >= int(clip.r): continue
      fb[rowOff + px] = color

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
    markDirty(ed)
    invalidateFrom(ed, row)

proc saveCurrent*(ed: ptr Editor) =
  if ed.buf.path.len == 0: return
  if ed.buf.path.startsWith("diff://"): return
  let content = ed.buf.lines.join("\n")
  if saveAtomic(ed.buf.path, content):
    let was = ed.buf.dirty
    ed.buf.dirty = false
    if was and editorTabsRepaintCb != nil: editorTabsRepaintCb()

proc editorPasteAtCursor*(ed: ptr Editor) =
  if ed == nil: return
  let txt = clipboardGet()
  if txt.len == 0: return
  pushUndo(ed, ekOther)
  if ed.buf.hasSel: deleteSelection(ed)
  let parts = txt.splitLines()
  for i, line in parts:
    if i > 0: insertNewline(ed)
    if line.len > 0: insertText(ed, line)
  noteEditEnd(ed)
  clampCursor(ed)
  followCursor(ed)
  elementRepaint(addr ed.e, nil)

proc activeMode*(ed: ptr Editor): CursorMode =
  if ed == nil or ed.tabs.len == 0: cmInsert
  else: ed.tabs[ed.activeIdx].mode

proc editorTabLabel*(ed: ptr Editor, idx: int): string =
  if ed == nil or idx < 0 or idx >= ed.tabs.len: return ""
  let b = ed.tabs[idx]
  let nm =
    if b.path.len == 0:
      "[scratch]"
    elif b.path.startsWith("diff://"):
      # diff://<hash>/<relpath>  →  "~ <hash> <basename>".
      # ASCII prefix only — the embedded bitmap font has no glyph for
      # multi-byte UTF-8, so a `Δ` here would render as `??` (each byte
      # falls back to the missing-glyph `?`).
      let rest = b.path[7 .. ^1]
      let slash = rest.find('/')
      if slash <= 0:
        "~ " & rest
      else:
        let hash = rest[0 ..< slash]
        let rel = rest[slash + 1 .. ^1]
        let base = extractFilename(rel)
        let short = if hash.len > 7: hash[0 ..< 7] else: hash
        "~ " & short & " " & base
    else:
      extractFilename(b.path)
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

# Accessors for the minimap and any other consumer that needs read-only buffer
# state without the editor module exporting EditorBuf's fields wholesale.
proc activeBuf*(ed: ptr Editor): ptr EditorBuf =
  if ed == nil or ed.tabs.len == 0: nil else: addr ed.tabs[ed.activeIdx]

proc bufLines*(b: ptr EditorBuf): lent seq[string] = b.lines
proc bufTopLine*(b: ptr EditorBuf): int = b.topLine
proc bufCursorRow*(b: ptr EditorBuf): int = b.cursorRow
proc bufDirtyFromRow*(b: ptr EditorBuf): int = b.dirtyFromRow
proc bufSyntax*(b: ptr EditorBuf): ptr SyntaxRule = b.syntax
proc bufLineStartStates*(b: ptr EditorBuf): ptr seq[uint8] = addr b.lineStartStates
proc bufVisibleRows*(ed: ptr Editor): int = visibleRows(ed)

# Minimap calls this to keep lineStartStates current up to whatever row it's
# about to tokenize.
proc bufRefreshStates*(ed: ptr Editor, throughRow: int) =
  refreshStates(ed, throughRow)

# Minimap click-to-jump: clamp topLine, follow cursor handling stays in editor.
proc bufSetTopLine*(ed: ptr Editor, top: int) =
  let n = ed.buf.lines.len
  let vr = visibleRows(ed)
  ed.buf.topLine = clamp(top, 0, max(0, n - vr))

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

proc visualRowFor(ed: ptr Editor, vrows: seq[VRow], row, col: int): int =
  ## Index in vrows of the visual row holding (row, col); -1 if off-screen.
  for i, vr in vrows:
    if vr.rowIdx != row: continue
    if not ed.buf.wrap:
      return i
    # Wrap mode: slice contains col (with the end-of-line edge case
    # — col == lineLen lands on the last segment).
    if (col >= vr.lo and col < vr.hi) or
       (col == vr.hi and
        (i + 1 >= vrows.len or vrows[i + 1].rowIdx != row)):
      return i
  -1

proc cursorVRowIdx(ed: ptr Editor, vrows: seq[VRow]): int =
  visualRowFor(ed, vrows, ed.buf.cursorRow, ed.buf.cursorCol)

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
      # Optional per-row tint (diff +/- lines). Painted before selection
      # so an active selection still wins visually. Covers content area
      # only — gutter is repainted last.
      let lineBg = highlight.lineBgColor(ed.buf.syntax, line)
      if lineBg != 0:
        drawBlock(painter,
                  Rectangle(l: contentBaseLeft, r: ed.e.bounds.r,
                            t: y, b: y + gH), lineBg)
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
        # Whitespace markers — overlay leading-space dots and tab bars in a
        # dimmed color (manual blend toward bg, no luigi alpha needed).
        let dim = dimToward(ui.theme.codeDefault, ui.theme.codeBackground, 0.35)
        var firstNonWS = 0
        while firstNonWS < line.len and
              (line[firstNonWS] == ' ' or line[firstNonWS] == '\t'):
          inc firstNonWS
        let cellOff = if ed.buf.wrap: vrow.lo else: 0
        let visLo = cellOff
        let visHi = if ed.buf.wrap: vrow.hi else: line.len
        for i in visLo ..< min(line.len, visHi):
          let c = line[i]
          if c == ' ' and i < firstNonWS:
            let cx = leftX + cint(i - cellOff) * gW
            let dotW: cint = 2
            let dotH: cint = 2
            drawDot(painter,
                    cx + (gW - dotW) div 2,
                    y + (gH - dotH) div 2,
                    dotW, dotH, dim)
          elif c == '\t':
            let cx = leftX + cint(i - cellOff) * gW
            let mid = y + gH div 2
            drawBlock(painter,
                      Rectangle(l: cx + 2, r: cx + gW - 2,
                                t: mid, b: mid + 1), dim)
    # cursor
    let cVI = cursorVRowIdx(ed, vrows)
    let mode = ed.buf.mode
    let focused = (element.window != nil and element.window.focused == element)
    if cVI >= 0:
      let vrow = vrows[cVI]
      let leftX = if ed.buf.wrap: contentBaseLeft else: contentLeft0
      let cellOff = if ed.buf.wrap: vrow.lo else: 0
      let cx = leftX + cint(ed.buf.cursorCol - cellOff) * gW
      let cy = vrow.y
      if mode == cmInsert:
        drawInvert(painter, Rectangle(l: cx, r: cx + gW, t: cy, b: cy + gH))
      else:
        if (not focused) or cursorBlinkOn:
          drawBlock(painter,
                    Rectangle(l: cx, r: cx + 2, t: cy, b: cy + gH),
                    ui.theme.text)
    # extra cursors — same rendering as primary, plus a thin underline so
    # users can pick out which is the "real" one for selection / saved state.
    for ec in ed.buf.extraCursors:
      let evi = visualRowFor(ed, vrows, ec.row, ec.col)
      if evi < 0: continue
      let vrow = vrows[evi]
      let leftX = if ed.buf.wrap: contentBaseLeft else: contentLeft0
      let cellOff = if ed.buf.wrap: vrow.lo else: 0
      let cx = leftX + cint(ec.col - cellOff) * gW
      let cy = vrow.y
      if mode == cmInsert:
        drawInvert(painter, Rectangle(l: cx, r: cx + gW, t: cy, b: cy + gH))
      else:
        if (not focused) or cursorBlinkOn:
          drawBlock(painter,
                    Rectangle(l: cx, r: cx + 2, t: cy, b: cy + gH),
                    ui.theme.text)
      drawBlock(painter,
                Rectangle(l: cx, r: cx + gW, t: cy + gH - 1, b: cy + gH),
                currentPalette.accent)
    # Gutter painted last so any leftward bleed from horizontal scroll
    # (tokens / selection rects with x < gutterRight) gets covered cleanly.
    # Driven by vrows so wrap continuations get blank gutter slots and the
    # current-line highlight tracks the actual logical cursor row.
    if gutterW > 0:
      paintGutter(ed, painter, by, gW, gH, gutterW, vrows)
    # focus border
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, ed.e.bounds, currentPalette.accent,
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
      if w.alt:
        # Alt+click adds a non-selection cursor at the click; primary stays.
        # We also drop any active selection — extras + selection is a weird
        # state because extras have no selection of their own and the next
        # edit would otherwise delete only the primary's selection.
        ed.buf.hasSel = false
        # Clamp to line bounds immediately so a click past EOL snaps to the
        # line end on creation rather than waiting for the first keystroke.
        if ed.buf.lines.len == 0: ed.buf.lines.add("")
        var r = row
        var c = col
        if r < 0: r = 0
        if r >= ed.buf.lines.len: r = ed.buf.lines.len - 1
        let ll = ed.buf.lines[r].len
        if c < 0: c = 0
        if c > ll: c = ll
        var dup = (r == ed.buf.cursorRow and c == ed.buf.cursorCol)
        if not dup:
          for ec in ed.buf.extraCursors:
            if ec.row == r and ec.col == c: dup = true; break
        if not dup:
          ed.buf.extraCursors.add(ExtraCursor(row: r, col: c))
        elementRepaint(element, nil)
        return 1
      ed.buf.extraCursors.setLen(0)
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
      # Motion always collapses multi-cursor back to primary; extras are pure
      # insertion points and don't track their own selections, so any motion
      # is the cleanest signal to drop them.
      if ed.buf.extraCursors.len > 0:
        ed.buf.extraCursors.setLen(0)
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

    # Esc collapses extra cursors and clears any active selection. If neither
    # is set we leave it for whatever else might bind Esc upstream.
    if code == int(KEYCODE_ESCAPE):
      var changed = false
      if ed.buf.extraCursors.len > 0:
        ed.buf.extraCursors.setLen(0); changed = true
      if ed.buf.hasSel:
        ed.buf.hasSel = false; changed = true
      if changed:
        elementRepaint(element, nil)
        return 1
      return 0

    # Alt+Shift+Left/Right/H/L cycles the active tab (editor pane swaps to
    # the new buffer); Alt+Ctrl+Left/Right/H/L reorders the active tab in
    # place. Lets you both navigate and rearrange without leaving the editor
    # body. Other Alt / Shift+Alt chords belong to the IDE (pane navigation,
    # window shortcuts).
    if alt and ctrl and not shift:
      if code == int(KEYCODE_LEFT) or code == int(KEYCODE_LETTER('H')):
        editorTabMove(ed, -1)
        return 1
      if code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L')):
        editorTabMove(ed, 1)
        return 1
    if alt and shift:
      if code == int(KEYCODE_LEFT) or code == int(KEYCODE_LETTER('H')):
        editorTabPrev(ed)
        return 1
      if code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L')):
        editorTabNext(ed)
        return 1
    if alt: return 0

    if code == int(KEYCODE_INSERT):
      ed.buf.mode =
        if ed.buf.mode == cmInsert: cmNormal else: cmInsert
      elementRepaint(element, nil)
      return 1

    if ctrl:
      # Ctrl + (arrow | h/j/k/l | Home/End) = step-bigger motion.
      # Shift extends selection (standard convention).
      let isLeft  = code == int(KEYCODE_LEFT)  or code == int(KEYCODE_LETTER('H'))
      let isRight = code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L'))
      let isDown  = code == int(KEYCODE_DOWN)  or code == int(KEYCODE_LETTER('J'))
      let isUp    = code == int(KEYCODE_UP)    or code == int(KEYCODE_LETTER('K'))
      let isHome  = code == int(KEYCODE_HOME)
      let isEnd   = code == int(KEYCODE_END)
      if isLeft or isRight or isDown or isUp or isHome or isEnd:
        motionStart()
        if   isLeft:  wordBack(ed)
        elif isRight: wordForward(ed)
        elif isDown:  ed.buf.cursorRow += max(1, config.cursorJumpLines)
        elif isUp:    ed.buf.cursorRow -= max(1, config.cursorJumpLines)
        elif isHome:  bufferStart(ed)
        elif isEnd:   bufferEnd(ed)
        clampCursor(ed)
        followCursor(ed)
        motionEnd()
        elementRepaint(element, nil)
        return 1

      # Ctrl+N = jump to end of current line (Shift extends selection).
      if code == int(KEYCODE_LETTER('N')):
        motionStart()
        ed.buf.cursorCol = ed.buf.lines[ed.buf.cursorRow].len
        clampCursor(ed)
        followCursor(ed)
        motionEnd()
        elementRepaint(element, nil)
        return 1

      # Ctrl + letter = action.
      if code == int(KEYCODE_LETTER('A')):
        selAll(ed)
      elif code == int(KEYCODE_LETTER('S')):
        saveCurrent(ed)
      elif code == int(KEYCODE_LETTER('C')):
        if ed.buf.hasSel: clipboardSetBoth(selCopyText(ed))
      elif code == int(KEYCODE_LETTER('V')):
        let txt = clipboardGet()
        if txt.len > 0:
          pushUndo(ed, ekOther)
          editStart()
          if ed.buf.extraCursors.len == 0:
            let parts = txt.splitLines()
            for i, line in parts:
              if i > 0: insertNewline(ed)
              if line.len > 0: insertText(ed, line)
          else:
            multiInsertText(ed, txt)
          noteEditEnd(ed)
      elif code == int(KEYCODE_LETTER('D')):
        # killToEnd moved off Ctrl+K so K could mirror Up.
        pushUndo(ed, ekOther)
        editStart(); killToEnd(ed)
        noteEditEnd(ed)
      elif code == int(KEYCODE_LETTER('Z')):
        if shift: editorRedo(ed) else: editorUndo(ed)
        return 1
      elif code == int(KEYCODE_LETTER('Y')):
        editorRedo(ed)
        return 1
      else:
        return 0
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
      pushUndo(ed, ekOther)
      editStart()
      if ed.buf.extraCursors.len == 0: insertNewline(ed)
      else: multiInsertText(ed, "\n")
      noteEditEnd(ed)
    elif code == int(KEYCODE_BACKSPACE):
      if ed.buf.hasSel:
        pushUndo(ed, ekOther); deleteSelection(ed)
      elif ed.buf.extraCursors.len == 0:
        pushUndo(ed, ekBackspace); backspace(ed)
      else:
        pushUndo(ed, ekBackspace); multiBackspace(ed)
      noteEditEnd(ed)
    elif code == int(KEYCODE_TAB):
      pushUndo(ed, ekOther)
      editStart()
      let ind = config.indentString()
      if ed.buf.extraCursors.len == 0: insertText(ed, ind)
      else: multiInsertText(ed, ind)
      noteEditEnd(ed)
    elif k.textBytes > 0:
      let kind = if ed.buf.hasSel: ekOther else: ekInsert
      pushUndo(ed, kind)
      editStart()
      var s = newString(int(k.textBytes))
      copyMem(addr s[0], k.text, int(k.textBytes))
      if ed.buf.extraCursors.len == 0: insertText(ed, s)
      else: multiInsertText(ed, s)
      noteEditEnd(ed)
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
