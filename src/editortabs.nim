import luigi, font, editor

const
  tabPadX*: cint = 8
  tabPadY*: cint = 3

type EditorTabs* = object
  e*: Element
  pinnedFocused*: bool

var theEditorTabs*: ptr EditorTabs

proc tabsHeight*(): cint =
  let (_, gH) = glyphDims()
  gH + 2 * tabPadY

proc pinnedTabWidth(): cint =
  let (gW, _) = glyphDims()
  gW + 2 * tabPadX     # 1-char label + padding

proc pinnedTabLabel(): string =
  if editorWrapEnabled(theEditor): "*" else: "-"

const pinnedTabSentinel = -1

proc tabAtX(lx: cint): int =
  ## Returns: pinnedTabSentinel for the wrap-toggle tab, or 0..n-1 for
  ## regular tabs, or -2 for misses.
  let pw = pinnedTabWidth()
  if lx >= 0 and lx < pw: return pinnedTabSentinel
  if theEditor == nil: return -2
  let (gW, _) = glyphDims()
  var x: cint = pw
  for i in 0 ..< editorTabCount(theEditor):
    let label = editorTabLabel(theEditor, i)
    let w = cint(label.len) * gW + 2 * tabPadX
    if lx >= x and lx < x + w: return i
    x += w
  -2

proc focusEditor() =
  if theEditor != nil:
    elementFocus(addr theEditor.e)
    elementRepaint(addr theEditor.e, nil)

proc paintStrip(t: ptr EditorTabs, painter: ptr Painter) =
  drawBlock(painter, t.e.bounds, ui.theme.panel2)
  let (gW, _) = glyphDims()
  # --- pinned wrap-toggle tab (always present, leftmost) ----------------
  let pw = pinnedTabWidth()
  let pr = Rectangle(l: t.e.bounds.l, r: min(t.e.bounds.l + pw, t.e.bounds.r),
                     t: t.e.bounds.t, b: t.e.bounds.b)
  let pinnedActive = t.pinnedFocused
  let pinnedOn = editorWrapEnabled(theEditor)
  let pinnedBg =
    if pinnedActive: ui.theme.selected
    elif pinnedOn:   ui.theme.buttonHovered   # subtle "engaged" tint
    else:            ui.theme.panel2
  let pinnedFg =
    if pinnedActive: ui.theme.textSelected else: ui.theme.text
  drawBlock(painter, pr, pinnedBg)
  let plabel = pinnedTabLabel()
  drawString(painter, pr, plabel.cstring, plabel.len, pinnedFg,
             cint(ALIGN_CENTER), nil)
  if theEditor != nil:
    let activeIdx = editorActiveIdx(theEditor)
    let n = editorTabCount(theEditor)
    var x = t.e.bounds.l + pw
    for i in 0 ..< n:
      let label = editorTabLabel(theEditor, i)
      let w = cint(label.len) * gW + 2 * tabPadX
      if x >= t.e.bounds.r: break
      let r = Rectangle(l: x, r: min(x + w, t.e.bounds.r),
                        t: t.e.bounds.t, b: t.e.bounds.b)
      let active = (i == activeIdx) and not t.pinnedFocused
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
      if idx == pinnedTabSentinel:
        editorWrapToggleActive()
        elementRepaint(element, nil)
      elif idx >= 0 and theEditor != nil:
        t.pinnedFocused = false
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
    # Enter on the focused pinned tab toggles wrap; otherwise Enter (along
    # with Down/Esc/j/k) drops focus back to the editor body.
    if code == int(KEYCODE_ENTER):
      if t.pinnedFocused:
        editorWrapToggleActive()
        elementRepaint(element, nil)
        return 1
      focusEditor()
      return 1
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_ESCAPE) or
       code == int(KEYCODE_LETTER('J')) or code == int(KEYCODE_LETTER('K')):
      focusEditor()
      return 1
    if code == int(KEYCODE_UP):
      return 1
    let n = if theEditor != nil: editorTabCount(theEditor) else: 0
    # Left / Right / h / l navigate the strip (ignoring modifiers).
    if code == int(KEYCODE_LEFT) or code == int(KEYCODE_LETTER('H')):
      if t.pinnedFocused:
        return 1   # already leftmost
      if n > 0 and editorActiveIdx(theEditor) == 0:
        t.pinnedFocused = true
      elif n > 0:
        let cur = editorActiveIdx(theEditor)
        editorTabSwitch(theEditor, cur - 1)
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L')):
      if t.pinnedFocused:
        t.pinnedFocused = false
      elif n > 0:
        let cur = editorActiveIdx(theEditor)
        editorTabSwitch(theEditor, (cur + 1) mod n)
      elementRepaint(element, nil)
      return 1
    if alt: return 1
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
