import luigi, font

type
  Provider* = object
    state*: pointer
    name*: string
    rowCount*:  proc(s: pointer): int {.nimcall.}
    rowText*:   proc(s: pointer, i: int): string {.nimcall.}
    onPaintRow*: proc(s: pointer, i: int, p: ptr Painter, r: Rectangle, sel: bool) {.nimcall.}
    onSelect*:  proc(s: pointer, i: int) {.nimcall.}
    onContext*: proc(s: pointer, i: int) {.nimcall.}
    onKey*:     proc(s: pointer, code: cint, ctrl, shift: bool): bool {.nimcall.}
    onBack*:    proc(s: pointer) {.nimcall.}

  PaneFrame = object
    provider: Provider
    selected, topLine: int

  ResultsPane* = object
    e*: Element
    current*: Provider
    stack: seq[PaneFrame]
    selected*, topLine*: int

var thePane*: ptr ResultsPane

proc visibleRows(p: ptr ResultsPane): int =
  let (_, gH) = glyphDims()
  max(1, int(p.e.bounds.b - p.e.bounds.t) div max(1, int(gH)))

proc rowCount(p: ptr ResultsPane): int =
  if p.current.rowCount == nil: 0 else: p.current.rowCount(p.current.state)

proc clampScroll(p: ptr ResultsPane) =
  let vr = visibleRows(p)
  let n = rowCount(p)
  let maxTop = max(0, n - vr)
  if p.topLine < 0: p.topLine = 0
  if p.topLine > maxTop: p.topLine = maxTop
  if p.selected < 0: p.selected = 0
  if p.selected >= n: p.selected = max(0, n - 1)

proc followSelection(p: ptr ResultsPane) =
  let vr = visibleRows(p)
  if p.selected < p.topLine:
    p.topLine = p.selected
  elif p.selected >= p.topLine + vr:
    p.topLine = p.selected - vr + 1
  if p.topLine < 0: p.topLine = 0

proc paneResetSelection*(p: ptr ResultsPane) =
  p.selected = 0
  p.topLine = 0
  if p.e.window != nil:
    elementRepaint(addr p.e, nil)

proc paneSetProvider*(p: ptr ResultsPane, prov: Provider) =
  p.current = prov
  p.stack.setLen(0)
  p.selected = 0
  p.topLine = 0
  if p.e.window != nil:
    elementRepaint(addr p.e, nil)

proc panePushProvider*(p: ptr ResultsPane, prov: Provider) =
  if p.current.rowCount != nil:
    p.stack.add(PaneFrame(provider: p.current,
                          selected: p.selected, topLine: p.topLine))
  p.current = prov
  p.selected = 0
  p.topLine = 0
  if p.e.window != nil:
    elementRepaint(addr p.e, nil)

proc paneSwapTo*(p: ptr ResultsPane, prov: Provider) =
  ## Push prov on top, or just reset selection if prov is already current.
  ## Always re-focuses the pane.
  if p == nil: return
  if p.current.name == prov.name:
    paneResetSelection(p)
  else:
    panePushProvider(p, prov)
  if p.e.window != nil:
    elementFocus(addr p.e)

proc panePopProvider*(p: ptr ResultsPane): bool =
  if p.stack.len == 0: return false
  let frame = p.stack.pop()
  p.current = frame.provider
  p.selected = frame.selected
  p.topLine = frame.topLine
  if p.e.window != nil:
    elementRepaint(addr p.e, nil)
  return true

proc paintDefaultRow(p: ptr ResultsPane, idx: int,
                     painter: ptr Painter, r: Rectangle, sel: bool) =
  let bg = if sel: ui.theme.selected else: ui.theme.panel1
  drawBlock(painter, r, bg)
  let txt = if p.current.rowText != nil: p.current.rowText(p.current.state, idx) else: ""
  if txt.len > 0:
    let color = if sel: ui.theme.textSelected else: ui.theme.text
    drawString(painter, r, txt.cstring, txt.len, color, cint(ALIGN_LEFT), nil)

proc rowAt(p: ptr ResultsPane, ly: cint): int =
  let (_, gH) = glyphDims()
  p.topLine + int(ly div max(1, gH))

proc paneMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let p = cast[ptr ResultsPane](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let (_, gH) = glyphDims()
    let bx = element.bounds.l
    let by = element.bounds.t
    let vr = visibleRows(p)
    let n = rowCount(p)
    for i in 0 ..< vr:
      let idx = p.topLine + i
      if idx >= n: break
      let y = by + cint(i) * gH
      let rowRect = Rectangle(l: bx, r: element.bounds.r, t: y, b: y + gH)
      let isSel = (idx == p.selected)
      if p.current.onPaintRow != nil:
        p.current.onPaintRow(p.current.state, idx, painter, rowRect, isSel)
      else:
        paintDefaultRow(p, idx, painter, rowRect, isSel)
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, element.bounds, 0x9253be'u32,
                 Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let ly = w.cursorY - element.bounds.t
      let idx = rowAt(p, ly)
      let n = rowCount(p)
      if idx >= 0 and idx < n:
        p.selected = idx
        if p.current.onSelect != nil:
          p.current.onSelect(p.current.state, idx)
        elementRepaint(element, nil)
    return 1

  elif message == msgRightDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let ly = w.cursorY - element.bounds.t
      let idx = rowAt(p, ly)
      let n = rowCount(p)
      if idx >= 0 and idx < n:
        p.selected = idx
        elementRepaint(element, nil)
        if p.current.onContext != nil:
          p.current.onContext(p.current.state, idx)
    return 1

  elif message == msgMouseWheel:
    p.topLine += int(di) div 60
    clampScroll(p)
    elementRepaint(element, nil)
    return 1

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if w != nil and w.alt: return 0
    let code = k.code
    let ctrl  = (w != nil and w.ctrl)
    let shift = (w != nil and w.shift)

    if p.current.onKey != nil and p.current.onKey(p.current.state, code.cint, ctrl, shift):
      followSelection(p)
      elementRepaint(element, nil)
      return 1

    let n = rowCount(p)
    if n == 0: return 0
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      if p.selected < n - 1: inc p.selected
    elif code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      if p.selected > 0: dec p.selected
    elif code == int(KEYCODE_ENTER):
      if p.current.onSelect != nil:
        p.current.onSelect(p.current.state, p.selected)
    elif code == int(KEYCODE_ESCAPE):
      if not panePopProvider(p):
        if p.current.onBack != nil:
          p.current.onBack(p.current.state)
    else:
      return 0
    followSelection(p)
    elementRepaint(element, nil)
    return 1

  return 0

proc paneCreate*(parent: ptr Element, flags: uint32 = 0): ptr ResultsPane =
  let e = elementCreate(csize_t(sizeof(ResultsPane)), parent,
                        flags or ELEMENT_TAB_STOP,
                        paneMessage, "ResultsPane")
  let p = cast[ptr ResultsPane](e)
  p.selected = 0
  p.topLine = 0
  thePane = p
  return p
