import luigi, font, editor

const
  tabPadX*: cint = 8
  tabPadY*: cint = 3

type EditorTabs* = object
  e*: Element

var theEditorTabs*: ptr EditorTabs

proc tabsHeight*(): cint =
  let (_, gH) = glyphDims()
  gH + 2 * tabPadY

proc tabAtX(lx: cint): int =
  if theEditor == nil: return -1
  let (gW, _) = glyphDims()
  var x: cint = 0
  for i in 0 ..< editorTabCount(theEditor):
    let label = editorTabLabel(theEditor, i)
    let w = cint(label.len) * gW + 2 * tabPadX
    if lx >= x and lx < x + w: return i
    x += w
  -1

proc focusEditor() =
  if theEditor != nil:
    elementFocus(addr theEditor.e)
    elementRepaint(addr theEditor.e, nil)

proc paintStrip(t: ptr EditorTabs, painter: ptr Painter) =
  drawBlock(painter, t.e.bounds, ui.theme.panel2)
  if theEditor == nil: return
  let (gW, _) = glyphDims()
  let activeIdx = editorActiveIdx(theEditor)
  let n = editorTabCount(theEditor)
  var x = t.e.bounds.l
  for i in 0 ..< n:
    let label = editorTabLabel(theEditor, i)
    let w = cint(label.len) * gW + 2 * tabPadX
    if x >= t.e.bounds.r: break
    let r = Rectangle(l: x, r: min(x + w, t.e.bounds.r),
                      t: t.e.bounds.t, b: t.e.bounds.b)
    let active = (i == activeIdx)
    let bg = if active: ui.theme.selected else: ui.theme.panel2
    drawBlock(painter, r, bg)
    let fg = if active: ui.theme.textSelected else: ui.theme.text
    drawString(painter, r, label.cstring, label.len, fg, cint(ALIGN_CENTER), nil)
    x += w
  # Bottom border under the strip.
  drawBlock(painter,
            Rectangle(l: t.e.bounds.l, r: t.e.bounds.r,
                      t: t.e.bounds.b - 1, b: t.e.bounds.b),
            ui.theme.border)

proc tabsMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let t = cast[ptr EditorTabs](element)

  if message == msgGetHeight:
    return tabsHeight()

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    paintStrip(t, painter)
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, t.e.bounds, 0x9253be'u32,
                 Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let lx = w.cursorX - element.bounds.l
      let idx = tabAtX(lx)
      if idx >= 0 and theEditor != nil:
        editorTabSwitch(theEditor, idx)
        focusEditor()
        elementRepaint(element, nil)
    return 1

  elif message == msgUpdate:
    elementRepaint(element, nil)
    return 0

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let win = element.window
    let alt = (win != nil and win.alt)
    let code = k.code
    # Down (with or without alt) drops focus back to the editor body.
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_ENTER) or
       code == int(KEYCODE_ESCAPE) or code == int(KEYCODE_LETTER('J')) or
       code == int(KEYCODE_LETTER('K')):
      focusEditor()
      return 1
    if code == int(KEYCODE_UP):
      # already at top of col 1 — consume regardless of modifier.
      return 1
    if theEditor == nil: return 0
    let n = editorTabCount(theEditor)
    if n <= 0: return 0
    # Left / Right / h / l switch tabs IGNORING all modifiers — keeps the
    # tabs pane self-contained (Alt+H/L don't pane-cross from here) and
    # forgives fat-fingered Alt+Left / Alt+Right.
    if code == int(KEYCODE_LEFT) or code == int(KEYCODE_LETTER('H')):
      let cur = editorActiveIdx(theEditor)
      editorTabSwitch(theEditor, (cur - 1 + n) mod n)
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L')):
      let cur = editorActiveIdx(theEditor)
      editorTabSwitch(theEditor, (cur + 1) mod n)
      elementRepaint(element, nil)
      return 1
    if alt: return 1   # consume any other Alt+key so it doesn't pane-cross
    return 0

  return 0

proc editorTabsFocus*() =
  if theEditorTabs != nil:
    elementFocus(addr theEditorTabs.e)
    elementRepaint(addr theEditorTabs.e, nil)

proc editorTabsCreate*(parent: ptr Element, flags: uint32 = 0): ptr EditorTabs =
  let e = elementCreate(csize_t(sizeof(EditorTabs)), parent,
                        flags or ELEMENT_H_FILL or ELEMENT_TAB_STOP,
                        tabsMessage, "EditorTabs")
  let t = cast[ptr EditorTabs](e)
  theEditorTabs = t
  editor.editorAltUpCb = proc() = editorTabsFocus()
  return t
