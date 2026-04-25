import std/strutils
import luigi, commands

when defined(linux):
  {.compile: "prawk_x11.c".}
  {.passL: "-lX11".}
  proc prawk_x_focus_menu(w: ptr Window) {.importc, cdecl.}

type
  MenuOption = object
    label: cstring
    command: string
    args: seq[string]

  MenuItem = object
    label: cstring
    x, w: cint
    options: seq[MenuOption]

  Menubar* = object
    e*: Element
    items: array[3, MenuItem]
    hovered: int
    prevFocus: ptr Element
    palette*: bool
    palBuf: string

proc menusClose(): bool {.cdecl, importc: "_UIMenusClose".}

const
  padX: cint = 10
  padY: cint = 3

proc hitItem(mb: ptr Menubar, localX: cint): int =
  for i in 0 ..< mb.items.len:
    let it = mb.items[i]
    if localX >= it.x and localX < it.x + it.w: return i
  return -1

proc runOption(cp: pointer) {.cdecl.} =
  if cp == nil: return
  let o = cast[ptr MenuOption](cp)
  if o.command.len > 0:
    discard runCommand(o.command, o.args)

proc firstChild(e: ptr Element): ptr Element =
  cast[ptr Element](e.children)

proc nextSibling(e: ptr Element): ptr Element = e.next

proc lastSibling(first: ptr Element): ptr Element =
  var cur = first
  while cur != nil and cur.next != nil: cur = cur.next
  cur

proc prevSibling(first: ptr Element, target: ptr Element): ptr Element =
  var cur = first
  var prev: ptr Element = nil
  while cur != nil and cur != target:
    prev = cur
    cur = cur.next
  prev

proc menuButtonMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    let first = firstChild(element.parent)
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      var nxt = nextSibling(element)
      if nxt == nil: nxt = first
      if nxt != nil: elementFocus(nxt)
      return 1
    if code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      var prv = prevSibling(first, element)
      if prv == nil: prv = lastSibling(first)
      if prv != nil: elementFocus(prv)
      return 1
    if code == int(KEYCODE_ENTER):
      discard elementMessage(element, msgClicked, 0, nil)
      discard menusClose()
      return 1
    if code == int(KEYCODE_ESCAPE):
      discard menusClose()
      return 1
  elif message == msgClicked:
    discard menusClose()
    return 0
  return 0

proc spawnMenu(mb: ptr Menubar, idx: int) =
  if idx < 0 or idx >= mb.items.len: return
  if mb.items[idx].options.len == 0: return
  let m = menuCreate(addr mb.e, 0)
  for i in 0 ..< mb.items[idx].options.len:
    let optPtr = addr mb.items[idx].options[i]
    menuAddItem(m, 0, mb.items[idx].options[i].label,
                invoke = runOption, cp = cast[pointer](optPtr))
  menuShow(m)
  # override each button's messageUser for keyboard nav, then focus first
  var child = firstChild(addr m.e)
  var firstButton: ptr Element = nil
  while child != nil:
    if child.cClassName != nil and $child.cClassName == "Button":
      child.messageUser = menuButtonMessage
      if firstButton == nil: firstButton = child
    child = child.next
  if firstButton != nil:
    elementFocus(firstButton)
  when defined(linux):
    # luigi doesn't transfer X11 keyboard focus to the menu popup, so keys
    # still go to the main window. nudge focus via a tiny C helper.
    if m.e.window != nil:
      prawk_x_focus_menu(m.e.window)

proc openFileMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 0)

proc openEditMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 1)

proc openViewMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 2)

proc enterPalette*(mb: ptr Menubar) =
  if mb.palette: return
  discard menusClose()
  mb.palette = true
  mb.palBuf = ""
  if mb.e.window != nil:
    mb.prevFocus = mb.e.window.focused
  elementFocus(addr mb.e)
  elementRepaint(addr mb.e, nil)

proc exitPalette*(mb: ptr Menubar) =
  if not mb.palette: return
  mb.palette = false
  mb.palBuf = ""
  let prev = mb.prevFocus
  mb.prevFocus = nil
  if prev != nil:
    elementFocus(prev)
    elementRepaint(prev, nil)
  elementRepaint(addr mb.e, nil)

proc paletteOpenCb*(cp: pointer) {.cdecl.} =
  if cp == nil: return
  enterPalette(cast[ptr Menubar](cp))

proc executePalette(mb: ptr Menubar) =
  let line = mb.palBuf.strip()
  if line.len > 0:
    let parts = line.splitWhitespace()
    let name = parts[0]
    let args = if parts.len > 1: parts[1 .. ^1] else: @[]
    discard runCommand(name, args)
  exitPalette(mb)

proc menubarMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let mb = cast[ptr Menubar](element)

  if message == msgGetHeight:
    let gH = if ui.activeFont != nil: ui.activeFont.glyphHeight else: 16.cint
    return gH + 2 * padY

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    if mb.palette:
      drawBlock(painter, element.bounds, ui.theme.textboxFocused)
      let txt = ":" & mb.palBuf
      let promptRect = Rectangle(
        l: element.bounds.l + padX, r: element.bounds.r,
        t: element.bounds.t, b: element.bounds.b)
      drawString(painter, promptRect, txt.cstring, cast[pointer](txt.len),
                 ui.theme.text, cint(ALIGN_LEFT), nil)
      let textW = measureStringWidth(txt.cstring, cast[pointer](txt.len))
      let gW = if ui.activeFont != nil: ui.activeFont.glyphWidth else: 9.cint
      let cx = element.bounds.l + padX + textW
      drawInvert(painter, Rectangle(
        l: cx, r: cx + gW,
        t: element.bounds.t + padY, b: element.bounds.b - padY))
      return 1
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
      mb.items[i].x = x - element.bounds.l
      mb.items[i].w = w
      x += w
    return 1

  elif message == msgKeyTyped:
    if not mb.palette: return 0
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    if code == int(KEYCODE_ESCAPE):
      exitPalette(mb); return 1
    if code == int(KEYCODE_ENTER):
      executePalette(mb); return 1
    if code == int(KEYCODE_BACKSPACE):
      if mb.palBuf.len > 0:
        mb.palBuf.setLen(mb.palBuf.len - 1)
        elementRepaint(element, nil)
      return 1
    if k.textBytes > 0:
      var s = newString(int(k.textBytes))
      copyMem(addr s[0], k.text, int(k.textBytes))
      mb.palBuf.add(s)
      elementRepaint(element, nil)
      return 1
    return 1

  elif message == msgMouseMove:
    if mb.palette: return 0
    let w = element.window
    if w != nil:
      let lx = w.cursorX - element.bounds.l
      let h = hitItem(mb, lx)
      if h != mb.hovered:
        mb.hovered = h
        elementRepaint(element, nil)
    return 0

  elif message == msgLeftDown:
    if mb.palette: return 0
    let w = element.window
    if w == nil: return 0
    let lx = w.cursorX - element.bounds.l
    let h = hitItem(mb, lx)
    if h < 0: return 0
    spawnMenu(mb, h)
    return 1

  return 0

proc mkOption(label: cstring, cmd: string = "", args: seq[string] = @[]): MenuOption =
  MenuOption(label: label, command: cmd, args: args)

proc menubarCreate*(parent: ptr Element, flags: uint32 = 0): ptr Menubar =
  let e = elementCreate(csize_t(sizeof(Menubar)), parent, flags or ELEMENT_TAB_STOP,
                        menubarMessage, "Menubar")
  let mb = cast[ptr Menubar](e)
  mb.items[0] = MenuItem(label: cstring"File", options: @[
    mkOption("Load Parent As Project", "project.parent"),
    mkOption("Save",                   "editor.save"),
    mkOption("Save As..."),
    mkOption("Quit",                   "quit"),
  ])
  mb.items[1] = MenuItem(label: cstring"Edit", options: @[
    mkOption("Copy"),
    mkOption("Paste"),
    mkOption("Undo"),
    mkOption("Redo"),
  ])
  mb.items[2] = MenuItem(label: cstring"View", options: @[
    mkOption("Toggle Sidebar"),
    mkOption("Toggle Fullscreen"),
  ])
  mb.hovered = -1
  return mb
