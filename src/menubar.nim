import luigi

type
  MenuItem = object
    label: cstring
    x, w: cint

  Menubar* = object
    e*: Element
    items: array[3, MenuItem]
    hovered: int
    pressed: int

const
  padX: cint = 10
  padY: cint = 3

proc noopInvoke(cp: pointer) {.cdecl.} = discard

proc spawnFileMenu(parent: ptr Element) =
  let m = menuCreate(parent, 0)
  menuAddItem(m, 0, "Open Folder...", invoke = noopInvoke)
  menuAddItem(m, 0, "Save",           invoke = noopInvoke)
  menuAddItem(m, 0, "Save As...",     invoke = noopInvoke)
  menuAddItem(m, 0, "Quit",           invoke = noopInvoke)
  menuShow(m)

proc spawnEditMenu(parent: ptr Element) =
  let m = menuCreate(parent, 0)
  menuAddItem(m, 0, "Copy",  invoke = noopInvoke)
  menuAddItem(m, 0, "Paste", invoke = noopInvoke)
  menuAddItem(m, 0, "Undo",  invoke = noopInvoke)
  menuAddItem(m, 0, "Redo",  invoke = noopInvoke)
  menuShow(m)

proc spawnViewMenu(parent: ptr Element) =
  let m = menuCreate(parent, 0)
  menuAddItem(m, 0, "Toggle Sidebar",    invoke = noopInvoke)
  menuAddItem(m, 0, "Toggle Fullscreen", invoke = noopInvoke)
  menuShow(m)

proc hitItem(mb: ptr Menubar, localX: cint): int =
  for i in 0 ..< mb.items.len:
    let it = mb.items[i]
    if localX >= it.x and localX < it.x + it.w: return i
  return -1

proc menubarMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let mb = cast[ptr Menubar](element)

  if message == msgGetHeight:
    let gH = if ui.activeFont != nil: ui.activeFont.glyphHeight else: 16.cint
    return gH + 2 * padY

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel2)
    var x: cint = element.bounds.l
    for i in 0 ..< mb.items.len:
      let label = mb.items[i].label
      let textW = measureStringWidth(label)
      let w = textW + 2 * padX
      let itemRect = Rectangle(l: x, r: x + w, t: element.bounds.t, b: element.bounds.b)
      let bg = if i == mb.hovered: ui.theme.buttonHovered else: ui.theme.panel2
      drawBlock(painter, itemRect, bg)
      drawString(painter, itemRect, label, castInt, ui.theme.text, cint(ALIGN_CENTER), nil)
      mb.items[i].x = x
      mb.items[i].w = w
      x += w
    return 1

  elif message == msgMouseMove:
    let w = element.window
    if w != nil:
      let localX = w.cursorX - element.bounds.l
      let h = hitItem(mb, w.cursorX)
      if h != mb.hovered:
        mb.hovered = h
        elementRepaint(element, nil)
      discard localX
    return 0

  elif message == msgLeftDown:
    let w = element.window
    if w == nil: return 0
    let h = hitItem(mb, w.cursorX)
    if h < 0: return 0
    case h
    of 0: spawnFileMenu(element)
    of 1: spawnEditMenu(element)
    of 2: spawnViewMenu(element)
    else: discard
    return 1

  return 0

proc menubarCreate*(parent: ptr Element, flags: uint32 = 0): ptr Menubar =
  let e = elementCreate(csize_t(sizeof(Menubar)), parent, flags,
                        menubarMessage, "Menubar")
  let mb = cast[ptr Menubar](e)
  mb.items[0] = MenuItem(label: cstring"File")
  mb.items[1] = MenuItem(label: cstring"Edit")
  mb.items[2] = MenuItem(label: cstring"View")
  mb.hovered = -1
  return mb
