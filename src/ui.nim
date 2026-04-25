import luigi
import term, pump, editor, menubar, tree
export luigi, editor, menubar

var
  leftCol, rightCol: ptr Element         # tree, editor
  middleTop, middleBottom: ptr Element   # termTop, termBottom
  lastMiddle: ptr Element                # remembers which terminal was used last

proc log(msg: string) =
  try: stderr.writeLine("[prawk] " & msg); stderr.flushFile()
  except IOError: discard

proc columnOf(e: ptr Element): int =
  if e == leftCol: 0
  elif e == middleTop or e == middleBottom: 1
  elif e == rightCol: 2
  else: -1

proc focusElement(target: ptr Element) =
  if target == nil: return
  let win = target.window
  let prev = if win != nil: win.focused else: nil
  elementFocus(target)
  if prev != nil and prev != target:
    elementRepaint(prev, nil)
  elementRepaint(target, nil)

proc focusCol(col: int) =
  case col
  of 0: focusElement(leftCol)
  of 1: focusElement(if lastMiddle != nil: lastMiddle else: middleTop)
  of 2: focusElement(rightCol)
  else: discard

proc onWinMsg(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if not w.alt: return 0

    let code = k.code
    let left  = code == int(KEYCODE_LETTER('H')) or code == int(KEYCODE_LEFT)
    let right = code == int(KEYCODE_LETTER('L')) or code == int(KEYCODE_RIGHT)
    let up    = code == int(KEYCODE_LETTER('K')) or code == int(KEYCODE_UP)
    let down  = code == int(KEYCODE_LETTER('J')) or code == int(KEYCODE_DOWN)
    if not (left or right or up or down): return 0

    let cur = element.window.focused
    let col = columnOf(cur)
    if col == 1 and cur != nil:
      lastMiddle = cur

    if left:
      if col == 2: focusCol(1)
      elif col == 1: focusCol(0)
    elif right:
      if col == 0: focusCol(1)
      elif col == 1: focusCol(2)
    elif down:
      if col == 1 and cur == middleTop: focusElement(middleBottom)
    elif up:
      if col == 1 and cur == middleBottom: focusElement(middleTop)
    return 1
  return 0

type UiRefs* = object
  window*: ptr Window
  rootPanel*: ptr Panel
  menubar*: ptr Menubar
  rootSplit*: ptr SplitPane
  sidebarSplit*: ptr SplitPane
  tree*: ptr FolderTree
  gitPane*: ptr Panel
  mainSplit*: ptr SplitPane
  termSplit*: ptr SplitPane
  termTop*: ptr Terminal
  termBottom*: ptr Terminal
  editor*: ptr Editor

proc stubPanel(parent: ptr Element, label: cstring): ptr Panel =
  result = panelCreate(parent, PANEL_GRAY or PANEL_EXPAND)
  discard labelCreate(addr result.e, 0, label)

proc buildUi*(): UiRefs =
  result.window = windowCreate(nil, 0, "prawk", 900, 600)

  result.rootPanel = panelCreate(addr result.window.e, PANEL_GRAY or PANEL_EXPAND)

  result.menubar = menubarCreate(addr result.rootPanel.e, ELEMENT_H_FILL)

  result.rootSplit = splitPaneCreate(addr result.rootPanel.e, ELEMENT_V_FILL or ELEMENT_H_FILL, 0.18)

  result.sidebarSplit = splitPaneCreate(addr result.rootSplit.e, SPLIT_PANE_VERTICAL, 0.55)
  result.tree = treeCreate(addr result.sidebarSplit.e)
  result.gitPane = stubPanel(addr result.sidebarSplit.e, "git (later)")

  result.mainSplit = splitPaneCreate(addr result.rootSplit.e, 0, 0.45)

  result.termSplit = splitPaneCreate(addr result.mainSplit.e, SPLIT_PANE_VERTICAL, 0.9)
  result.termTop    = terminalCreate(addr result.termSplit.e)
  result.termBottom = terminalCreate(addr result.termSplit.e)
  term.theTermBottom = result.termBottom

  result.editor = editorCreate(addr result.mainSplit.e)

  leftCol      = addr result.tree.e
  middleTop    = addr result.termTop.e
  middleBottom = addr result.termBottom.e
  rightCol     = addr result.editor.e
  lastMiddle   = middleBottom
  elementFocus(middleBottom)
  result.window.e.messageUser = onWinMsg
  log("ui built: tree=" & $cast[uint](leftCol) & " termT=" & $cast[uint](middleTop) &
      " termB=" & $cast[uint](middleBottom) & " editor=" & $cast[uint](rightCol))

  let mbCp = cast[pointer](result.menubar)
  windowRegisterShortcut(result.window, Shortcut(
    code: cint(KEYCODE_LETTER('D')), alt: true,
    invoke: paletteOpenCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: cint(KEYCODE_LETTER('F')), alt: true,
    invoke: openFileMenuCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: cint(KEYCODE_LETTER('E')), alt: true,
    invoke: openEditMenuCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: cint(KEYCODE_LETTER('V')), alt: true,
    invoke: openViewMenuCb, cp: mbCp))

  startPump(result.window)
