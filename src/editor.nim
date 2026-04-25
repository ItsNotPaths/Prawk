import std/[os, strutils]
import luigi

type
  EditorBuf = object
    lines: seq[string]
    cursorRow, cursorCol: int
    topLine: int
    path: string
    dirty: bool

  Editor* = object
    e*: Element
    buf: EditorBuf

var theEditor*: ptr Editor

proc glyphDims(): (cint, cint) =
  if ui.activeFont != nil:
    (ui.activeFont.glyphWidth, ui.activeFont.glyphHeight)
  else:
    (9.cint, 16.cint)

proc visibleRows(ed: ptr Editor): int =
  let (_, gH) = glyphDims()
  max(1, int(ed.e.bounds.b - ed.e.bounds.t) div max(1, int(gH)))

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

proc editorOpenFile*(ed: ptr Editor, path: string) =
  ed.buf.path = path
  ed.buf.lines = @[]
  ed.buf.cursorRow = 0
  ed.buf.cursorCol = 0
  ed.buf.topLine = 0
  ed.buf.dirty = false
  if fileExists(path):
    try:
      let content = readFile(path)
      ed.buf.lines = content.splitLines()
    except IOError:
      discard
  if ed.buf.lines.len == 0:
    ed.buf.lines.add("")
  elementRepaint(addr ed.e, nil)

proc insertText(ed: ptr Editor, s: string) =
  if s.len == 0: return
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1) & s & line.substr(col)
  ed.buf.cursorCol = col + s.len
  ed.buf.dirty = true

proc insertNewline(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  ed.buf.lines[row] = line.substr(0, col - 1)
  ed.buf.lines.insert(line.substr(col), row + 1)
  ed.buf.cursorRow = row + 1
  ed.buf.cursorCol = 0
  ed.buf.dirty = true

proc backspace(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  if col > 0:
    let line = ed.buf.lines[row]
    ed.buf.lines[row] = line.substr(0, col - 2) & line.substr(col)
    ed.buf.cursorCol = col - 1
    ed.buf.dirty = true
  elif row > 0:
    let prev = ed.buf.lines[row - 1]
    let cur = ed.buf.lines[row]
    ed.buf.cursorCol = prev.len
    ed.buf.lines[row - 1] = prev & cur
    ed.buf.lines.delete(row)
    ed.buf.cursorRow = row - 1
    ed.buf.dirty = true

proc killToEnd(ed: ptr Editor) =
  let row = ed.buf.cursorRow
  let col = ed.buf.cursorCol
  let line = ed.buf.lines[row]
  if col < line.len:
    ed.buf.lines[row] = line.substr(0, col - 1)
    ed.buf.dirty = true

proc saveCurrent*(ed: ptr Editor) =
  if ed.buf.path.len == 0: return
  let content = ed.buf.lines.join("\n")
  if saveAtomic(ed.buf.path, content):
    ed.buf.dirty = false

proc editorMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let ed = cast[ptr Editor](element)
  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    let (gW, gH) = glyphDims()
    drawBlock(painter, ed.e.bounds, ui.theme.codeBackground)
    let bx = ed.e.bounds.l
    let by = ed.e.bounds.t
    let vr = visibleRows(ed)
    for i in 0 ..< vr:
      let rowIdx = ed.buf.topLine + i
      if rowIdx >= ed.buf.lines.len: break
      let y = by + cint(i) * gH
      let rowRect = Rectangle(l: bx, r: ed.e.bounds.r, t: y, b: y + gH)
      let line = ed.buf.lines[rowIdx]
      if line.len > 0:
        discard drawStringHighlighted(painter, rowRect, line.cstring,
                                      line.len, 4.cint)
    # cursor
    let cRowOnScreen = ed.buf.cursorRow - ed.buf.topLine
    if cRowOnScreen >= 0 and cRowOnScreen < vr:
      let cx = bx + cint(ed.buf.cursorCol) * gW
      let cy = by + cint(cRowOnScreen) * gH
      drawInvert(painter, Rectangle(l: cx, r: cx + gW, t: cy, b: cy + gH))
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
    let cx = cint(di shr 16)  # not used; luigi passes cursor via window.cursorX/Y
    discard cx
    let w = element.window
    if w != nil:
      let lx = w.cursorX - ed.e.bounds.l
      let ly = w.cursorY - ed.e.bounds.t
      let row = ed.buf.topLine + int(ly div max(1, gH))
      let col = int(lx div max(1, gW))
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
    # Let Alt+... bubble up for pane navigation.
    if w != nil and w.alt: return 0
    let code = k.code
    let ctrl = (w != nil and w.ctrl)
    clampCursor(ed)

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
      insertText(ed, "    ")
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
  ed.buf.lines = @[""]
  theEditor = ed
  return ed
