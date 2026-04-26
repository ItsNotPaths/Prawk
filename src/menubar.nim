import std/strutils
import luigi, commands, config, clshell, font, theme, clipboard

type
  MenuOption = object
    label: string
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
    palCursor: int     # byte index into palBuf (0..palBuf.len)
    palAnchor: int     # selection anchor; meaningful when hasPalSel
    hasPalSel: bool
    menuOpen: bool

var theMenubar*: ptr Menubar

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

proc isButton(e: ptr Element): bool =
  e != nil and e.cClassName != nil and $e.cClassName == "Button"

proc nextButton(e: ptr Element): ptr Element =
  var cur = e.next
  while cur != nil and not isButton(cur): cur = cur.next
  cur

proc prevButton(first: ptr Element, target: ptr Element): ptr Element =
  # Walk from `first` toward `target`, remembering the most recent Button.
  # Skips non-Button siblings (luigi's menu has a ScrollBar before any button).
  var cur = first
  var lastBtn: ptr Element = nil
  while cur != nil and cur != target:
    if isButton(cur): lastBtn = cur
    cur = cur.next
  lastBtn

proc menuButtonMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    let first = firstChild(element.parent)
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      let nxt = nextButton(element)
      if nxt != nil: elementFocus(nxt)
      return 1
    if code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      let prv = prevButton(first, element)
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

proc findPopupMenuWin(): ptr Window =
  var w = cast[ptr Window](ui.windows)
  while w != nil:
    if (w.e.flags and WINDOW_MENU) != 0: return w
    w = w.next
  return nil

proc restoreFocusAfterMenu(mb: ptr Menubar) =
  mb.menuOpen = false
  let prev = mb.prevFocus
  mb.prevFocus = nil
  if prev != nil and mb.e.window != nil:
    elementFocus(prev)
    elementRepaint(prev, nil)

proc mkOption(label: string, cmd: string = "", args: seq[string] = @[]): MenuOption =
  MenuOption(label: label, command: cmd, args: args)

proc rebuildFileOptions(mb: ptr Menubar) =
  mb.items[0].options = @[
    mkOption("Load Parent As Project", "project.parent"),
    mkOption("Save",                   "editor.save"),
    mkOption("Save As..."),
    mkOption("Quit",                   "quit"),
  ]
  let recents = config.readRecents("recents.files")
  if recents.len > 0:
    mb.items[0].options.add(mkOption("--- Recent ---"))
    for p in recents:
      mb.items[0].options.add(mkOption(p, "editor.open", @[p]))

proc rebuildViewOptions(mb: ptr Menubar) =
  mb.items[2].options = @[
    mkOption("Toggle Sidebar"),
    mkOption("Toggle Fullscreen"),
    mkOption("--- Themes ---"),
  ]
  for n in theme.themeNames():
    let label = if n == theme.activeTheme: "* " & n else: "  " & n
    mb.items[2].options.add(mkOption(label, "theme", @[n]))

proc spawnMenu(mb: ptr Menubar, idx: int) =
  if idx < 0 or idx >= mb.items.len: return
  if idx == 0: rebuildFileOptions(mb)
  if idx == 2: rebuildViewOptions(mb)
  if mb.items[idx].options.len == 0: return
  # Override-redirect popups don't take X11 keyboard focus on tiling WMs,
  # so keep the main window focused and route keys through the menubar.
  if not mb.menuOpen and mb.e.window != nil:
    mb.prevFocus = mb.e.window.focused
  mb.menuOpen = true
  let m = menuCreate(addr mb.e, 0)
  for i in 0 ..< mb.items[idx].options.len:
    let optPtr = addr mb.items[idx].options[i]
    menuAddItem(m, 0, mb.items[idx].options[i].label.cstring,
                invoke = runOption, cp = cast[pointer](optPtr))
  menuShow(m)
  var child = firstChild(addr m.e)
  var firstButton: ptr Element = nil
  while child != nil:
    if child.cClassName != nil and $child.cClassName == "Button":
      child.messageUser = menuButtonMessage
      if firstButton == nil: firstButton = child
    child = child.next
  if firstButton != nil:
    elementFocus(firstButton)
  elementFocus(addr mb.e)

proc openFileMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 0)

proc openEditMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 1)

proc openViewMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 2)

proc resetPalState(mb: ptr Menubar) =
  mb.palBuf = ""
  mb.palCursor = 0
  mb.palAnchor = 0
  mb.hasPalSel = false

proc palSelRange(mb: ptr Menubar): tuple[lo, hi: int] =
  let a = mb.palAnchor
  let c = mb.palCursor
  if a <= c: (a, c) else: (c, a)

proc palSelText(mb: ptr Menubar): string =
  if not mb.hasPalSel: return ""
  let (lo, hi) = palSelRange(mb)
  let l = max(0, min(lo, mb.palBuf.len))
  let h = max(l, min(hi, mb.palBuf.len))
  mb.palBuf.substr(l, h - 1)

proc palDeleteSelection(mb: ptr Menubar) =
  if not mb.hasPalSel: return
  let (lo, hi) = palSelRange(mb)
  let l = max(0, min(lo, mb.palBuf.len))
  let h = max(l, min(hi, mb.palBuf.len))
  let head = if l <= 0: "" else: mb.palBuf.substr(0, l - 1)
  let tail = if h >= mb.palBuf.len: "" else: mb.palBuf.substr(h)
  mb.palBuf = head & tail
  mb.palCursor = l
  mb.hasPalSel = false

proc palClampCursor(mb: ptr Menubar) =
  if mb.palCursor < 0: mb.palCursor = 0
  if mb.palCursor > mb.palBuf.len: mb.palCursor = mb.palBuf.len

proc palByteFromX(mb: ptr Menubar, winX: cint): int =
  ## Convert a window-relative pixel X to a byte index in palBuf. Accounts for
  ## the leading `:` prompt and the optional spinner glyph that paint draws
  ## at the same offset. Monospace font, so plain division is fine.
  let (gW, _) = glyphDims()
  var leftX = mb.e.bounds.l + padX
  if clShellRunning():
    leftX += gW + 4
  let relX = max(cint(0), winX - leftX - gW)   # subtract prompt ":" width
  let cells = int((relX + gW div 2) div max(cint(1), gW))   # round to nearest cell
  max(0, min(mb.palBuf.len, cells))

proc palInsert(mb: ptr Menubar, s: string) =
  if s.len == 0: return
  if mb.hasPalSel: palDeleteSelection(mb)
  palClampCursor(mb)
  let head = if mb.palCursor <= 0: "" else: mb.palBuf.substr(0, mb.palCursor - 1)
  let tail = if mb.palCursor >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor)
  mb.palBuf = head & s & tail
  mb.palCursor += s.len

proc enterPalette*(mb: ptr Menubar) =
  if mb.palette: return
  discard menusClose()
  mb.palette = true
  resetPalState(mb)
  if mb.e.window != nil:
    mb.prevFocus = mb.e.window.focused
  elementFocus(addr mb.e)
  elementRepaint(addr mb.e, nil)

proc exitPalette*(mb: ptr Menubar) =
  if not mb.palette: return
  mb.palette = false
  resetPalState(mb)
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
  exitPalette(mb)
  if line.len > 0 and commands.clDispatchCb != nil:
    commands.clDispatchCb(line)

proc menubarMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let mb = cast[ptr Menubar](element)

  if message == msgGetHeight:
    let (_, gH) = glyphDims()
    return gH + 2 * padY

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    let (gW, _) = glyphDims()
    if mb.palette:
      drawBlock(painter, element.bounds, ui.theme.textboxFocused)
      var leftX = element.bounds.l + padX
      if clShellRunning():
        var spinBuf: array[2, char]
        spinBuf[0] = clShellSpinnerChar()
        spinBuf[1] = '\0'
        drawString(painter,
                   Rectangle(l: leftX, r: leftX + gW,
                             t: element.bounds.t, b: element.bounds.b),
                   cast[cstring](addr spinBuf[0]), 1,
                   ui.theme.text, cint(ALIGN_LEFT), nil)
        leftX += gW + 4
      let txt = ":" & mb.palBuf
      let promptRect = Rectangle(
        l: leftX, r: element.bounds.r,
        t: element.bounds.t, b: element.bounds.b)
      # Selection rect drawn under the text so glyphs remain readable.
      if mb.hasPalSel:
        let (lo, hi) = palSelRange(mb)
        let prefix = ":" & mb.palBuf.substr(0, lo - 1)
        let body   = mb.palBuf.substr(lo, hi - 1)
        let lx = leftX + measureStringWidth(prefix.cstring, prefix.len)
        let rx = lx + measureStringWidth(body.cstring, body.len)
        drawBlock(painter, Rectangle(
          l: lx, r: rx,
          t: element.bounds.t + padY, b: element.bounds.b - padY),
          ui.theme.selected)
      drawString(painter, promptRect, txt.cstring, txt.len,
                 ui.theme.text, cint(ALIGN_LEFT), nil)
      let beforeCursor = ":" & mb.palBuf.substr(0, mb.palCursor - 1)
      let cx = leftX + measureStringWidth(beforeCursor.cstring, beforeCursor.len)
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
      drawString(painter, itemRect, label, -1, ui.theme.text, cint(ALIGN_CENTER), nil)
      mb.items[i].x = x - element.bounds.l
      mb.items[i].w = w
      x += w
    if clShellRunning():
      var spinBuf: array[2, char]
      spinBuf[0] = clShellSpinnerChar()
      spinBuf[1] = '\0'
      let sx = x + padX
      drawString(painter,
                 Rectangle(l: sx, r: sx + gW,
                           t: element.bounds.t, b: element.bounds.b),
                 cast[cstring](addr spinBuf[0]), 1,
                 ui.theme.text, cint(ALIGN_LEFT), nil)
    return 1

  elif message == msgKeyTyped:
    if mb.menuOpen:
      let popup = findPopupMenuWin()
      if popup == nil:
        restoreFocusAfterMenu(mb)
        return 0
      let target = popup.focused
      var rc: cint = 0
      if target != nil:
        rc = elementMessage(target, msgKeyTyped, di, dp)
      if findPopupMenuWin() == nil:
        restoreFocusAfterMenu(mb)
      return rc
    if not mb.palette: return 0
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    let win = element.window
    let ctrl  = (win != nil and win.ctrl)
    let shift = (win != nil and win.shift)

    let preCursor = mb.palCursor

    template motionStart() =
      if shift:
        if not mb.hasPalSel:
          mb.palAnchor = preCursor
          mb.hasPalSel = true
      else:
        mb.hasPalSel = false

    template motionEnd() =
      if mb.hasPalSel and mb.palAnchor == mb.palCursor:
        mb.hasPalSel = false
      if mb.hasPalSel:
        clipboardSetPrimary(palSelText(mb))

    if ctrl and code == int(KEYCODE_LETTER('C')):
      if shift:
        clShellInterrupt()
      elif mb.hasPalSel:
        clipboardSetBoth(palSelText(mb))
      return 1
    if ctrl and code == int(KEYCODE_LETTER('A')):
      # Select all (Ctrl+A) — there's no Emacs line-start binding to clobber
      # in the single-line palette, so we use the standard shortcut.
      if mb.palBuf.len > 0:
        mb.palAnchor = 0
        mb.palCursor = mb.palBuf.len
        mb.hasPalSel = true
        clipboardSetPrimary(palSelText(mb))
        elementRepaint(element, nil)
      return 1
    if ctrl and code == int(KEYCODE_LETTER('V')):
      let txt = clipboardGet()
      if txt.len > 0:
        let nl = txt.find('\n')
        let body = if nl >= 0: txt[0 ..< nl] else: txt
        if body.len > 0:
          palInsert(mb, body)
          elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_ESCAPE):
      exitPalette(mb); return 1
    if code == int(KEYCODE_ENTER):
      executePalette(mb); return 1
    if code == int(KEYCODE_LEFT):
      motionStart()
      if mb.palCursor > 0: dec mb.palCursor
      motionEnd()
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_RIGHT):
      motionStart()
      if mb.palCursor < mb.palBuf.len: inc mb.palCursor
      motionEnd()
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_HOME):
      motionStart(); mb.palCursor = 0; motionEnd()
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_END):
      motionStart(); mb.palCursor = mb.palBuf.len; motionEnd()
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_BACKSPACE):
      if mb.hasPalSel:
        palDeleteSelection(mb)
      elif mb.palCursor > 0:
        let head = if mb.palCursor <= 1: "" else: mb.palBuf.substr(0, mb.palCursor - 2)
        let tail = if mb.palCursor >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor)
        mb.palBuf = head & tail
        dec mb.palCursor
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_DELETE):
      if mb.hasPalSel:
        palDeleteSelection(mb)
      elif mb.palCursor < mb.palBuf.len:
        let head = if mb.palCursor <= 0: "" else: mb.palBuf.substr(0, mb.palCursor - 1)
        let tail = if mb.palCursor + 1 >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor + 1)
        mb.palBuf = head & tail
      elementRepaint(element, nil)
      return 1
    if k.textBytes > 0:
      var s = newString(int(k.textBytes))
      copyMem(addr s[0], k.text, int(k.textBytes))
      palInsert(mb, s)
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
    let w = element.window
    if w == nil: return 0
    if mb.palette:
      mb.palCursor = palByteFromX(mb, w.cursorX)
      mb.palAnchor = mb.palCursor
      mb.hasPalSel = false
      elementRepaint(element, nil)
      return 1
    let lx = w.cursorX - element.bounds.l
    let h = hitItem(mb, lx)
    if h < 0: return 0
    spawnMenu(mb, h)
    return 1

  elif message == msgMouseDrag:
    if not mb.palette: return 0
    let w = element.window
    if w == nil: return 0
    mb.palCursor = palByteFromX(mb, w.cursorX)
    mb.hasPalSel = (mb.palCursor != mb.palAnchor)
    if mb.hasPalSel:
      clipboardSetPrimary(palSelText(mb))
    elementRepaint(element, nil)
    return 1

  return 0

proc openPaletteWith*(text: string) =
  if theMenubar == nil: return
  enterPalette(theMenubar)
  theMenubar.palBuf = text
  theMenubar.palCursor = text.len
  elementRepaint(addr theMenubar.e, nil)

proc menubarCreate*(parent: ptr Element, flags: uint32 = 0): ptr Menubar =
  let e = elementCreate(csize_t(sizeof(Menubar)), parent, flags or ELEMENT_TAB_STOP,
                        menubarMessage, "Menubar")
  let mb = cast[ptr Menubar](e)
  # File menu options are built lazily by rebuildFileOptions on each spawn
  # (recents are dynamic) — only the label is set here.
  mb.items[0] = MenuItem(label: cstring"File")
  mb.items[1] = MenuItem(label: cstring"Edit", options: @[
    mkOption("Copy"),
    mkOption("Paste"),
    mkOption("Undo"),
    mkOption("Redo"),
  ])
  # View options are built lazily by rebuildViewOptions on each spawn so the
  # active-theme marker stays accurate after :theme changes the selection.
  mb.items[2] = MenuItem(label: cstring"View")
  mb.hovered = -1
  theMenubar = mb
  commands.openPaletteWithCb = proc(text: string) = openPaletteWith(text)
  return mb
