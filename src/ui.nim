import luigi
import term, pump, editor, editortabs, menubar, tree, providers, config, resultspane, terminalstack, clshell, project, commands
export luigi, editor, menubar

var
  paneEl: ptr Element
  editorEl: ptr Element
  tabPaneEl: ptr Element
  termHostEl: ptr Element
  termStackRef: ptr TerminalStack

proc log(msg: string) =
  try: stderr.writeLine("[prawk] " & msg); stderr.flushFile()
  except IOError: discard

proc isInTermStack(e: ptr Element): bool =
  if termHostEl == nil or e == nil: return false
  var cur = e
  while cur != nil:
    if cur == termHostEl: return true
    cur = cur.parent
  false

proc columnOf(e: ptr Element): int =
  if e == nil: return -1
  if e == paneEl: return 0
  if e == editorEl or (tabPaneEl != nil and e == tabPaneEl): return 1
  if isInTermStack(e): return 2
  -1

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
  of 0: focusElement(paneEl)
  of 1: focusElement(editorEl)
  of 2:
    let t = stackFocusedTerminal(termStackRef)
    if t != nil: focusElement(addr t.e)
  else: discard

proc onWinMsg(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if not w.alt: return 0
    # Shift+Alt+* is reserved for window-level shortcuts (tab cycling,
    # terminal focus prev). Let them through to the shortcut layer.
    if w.shift: return 0

    let code = k.code
    let left  = code == int(KEYCODE_LETTER('H')) or code == int(KEYCODE_LEFT)
    let right = code == int(KEYCODE_LETTER('L')) or code == int(KEYCODE_RIGHT)
    let up    = code == int(KEYCODE_LETTER('K')) or code == int(KEYCODE_UP)
    let down  = code == int(KEYCODE_LETTER('J')) or code == int(KEYCODE_DOWN)
    if not (left or right or up or down): return 0

    let cur = w.focused
    let col = columnOf(cur)

    if left:
      if col == 2: focusCol(1)
      elif col == 1: focusCol(0)
    elif right:
      if col == 0: focusCol(1)
      elif col == 1: focusCol(2)
    elif down:
      if col == 2 and termStackRef != nil and termStackRef.terms.len > 1:
        let nextIdx = termStackRef.focusIdx + 1
        if nextIdx < termStackRef.terms.len:
          stackFocusAt(termStackRef, nextIdx)
    elif up:
      if col == 2 and termStackRef != nil and termStackRef.terms.len > 1:
        let prevIdx = termStackRef.focusIdx - 1
        if prevIdx >= 0:
          stackFocusAt(termStackRef, prevIdx)
    return 1
  return 0

proc paletteJumpCb(cp: pointer) {.cdecl.} =
  openPaletteWith("jump ")

proc paletteLockCb(cp: pointer) {.cdecl.} =
  ## Prefill the CL with `lock <focused-term-idx>` (1-based, matching the
  ## tN title bars) so Enter toggles the lock on the currently focused
  ## terminal. If no terminals exist, just `lock `.
  var prefix = "lock "
  if termStackRef != nil and termStackRef.terms.len > 0:
    prefix.add($(termStackRef.focusIdx + 1))
  openPaletteWith(prefix)

proc altQDispatch(cp: pointer) {.cdecl.} =
  ## Routes Alt+Q by focused column: editor (body or tab strip) → close active
  ## tab; terminal → kill.
  let win = if editorEl != nil: editorEl.window else: nil
  let f = if win != nil: win.focused else: nil
  if f != nil and (f == editorEl or
                   (tabPaneEl != nil and f == tabPaneEl)):
    discard runCommand("tab.close")
    return
  stackKillFocusedShortcut(cp)

type UiRefs* = object
  window*: ptr Window
  rootPanel*: ptr Panel
  menubar*: ptr Menubar
  rootSplit*: ptr SplitPane
  sidebarSplit*: ptr SplitPane
  innerSplit*: ptr SplitPane
  pane*: ptr ResultsPane
  gitPane*: ptr Panel
  editorCol*: ptr Panel
  editorTabs*: ptr EditorTabs
  editor*: ptr Editor
  termStack*: ptr TerminalStack

proc stubPanel(parent: ptr Element, label: cstring): ptr Panel =
  result = panelCreate(parent, PANEL_GRAY or PANEL_EXPAND)
  discard labelCreate(addr result.e, 0, label)

proc buildUi*(): UiRefs =
  result.window = windowCreate(nil, 0, "prawk", 900, 600)

  result.rootPanel = panelCreate(addr result.window.e, PANEL_GRAY or PANEL_EXPAND)

  result.menubar = menubarCreate(addr result.rootPanel.e, ELEMENT_H_FILL)

  # rootSplit: sidebar | innerSplit
  result.rootSplit = splitPaneCreate(addr result.rootPanel.e,
                                     ELEMENT_V_FILL or ELEMENT_H_FILL, 0.18)

  result.sidebarSplit = splitPaneCreate(addr result.rootSplit.e, SPLIT_PANE_VERTICAL, 0.55)
  result.pane = paneCreate(addr result.sidebarSplit.e)
  result.gitPane = stubPanel(addr result.sidebarSplit.e, "git (later)")
  treeInstall(result.pane)
  providersInstall(result.pane)
  clShellInit(project.projectRoot)
  clShellInstall(result.pane)

  # innerSplit: editorCol | terminal-stack
  result.innerSplit = splitPaneCreate(addr result.rootSplit.e, 0, 0.65)

  # editorCol: tab strip on top + editor body underneath, stacked vertically.
  result.editorCol = panelCreate(addr result.innerSplit.e, PANEL_GRAY or PANEL_EXPAND)
  result.editorTabs = editorTabsCreate(addr result.editorCol.e)
  result.editor = editorCreate(addr result.editorCol.e,
                               ELEMENT_V_FILL or ELEMENT_H_FILL)

  result.termStack = stackCreate(addr result.innerSplit.e)
  stackInstall(result.termStack)

  let saved = config.readSession()
  let n =
    if saved.len > 0: saved.len
    else: max(1, config.initialTerminals)
  for i in 0 ..< n:
    let nm = if i < saved.len: saved[i] else: ""
    discard stackAddTerminal(result.termStack, nm)

  paneEl       = addr result.pane.e
  editorEl     = addr result.editor.e
  tabPaneEl    = addr result.editorTabs.e
  termHostEl   = addr result.termStack.e
  termStackRef = result.termStack

  result.window.e.messageUser = onWinMsg
  log("ui built: pane=" & $cast[uint](paneEl) &
      " editor=" & $cast[uint](editorEl) &
      " termHost=" & $cast[uint](termHostEl) &
      " terms=" & $result.termStack.terms.len)

  let mbCp = cast[pointer](result.menubar)
  let stackCp = cast[pointer](result.termStack)
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('C')), alt: true,
    invoke: paletteOpenCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('F')), alt: true,
    invoke: openFileMenuCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('E')), alt: true,
    invoke: openEditMenuCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('V')), alt: true,
    invoke: openViewMenuCb, cp: mbCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('T')), alt: true,
    invoke: stackFocusNext, cp: stackCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('T')), alt: true, shift: true,
    invoke: stackFocusPrev, cp: stackCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('N')), alt: true,
    invoke: stackNewShortcut, cp: stackCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('Q')), alt: true,
    invoke: altQDispatch, cp: stackCp))
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('W')), alt: true,
    invoke: paletteJumpCb, cp: nil))
  # Shift+Alt+H/L/Left/Right used to be window-wide tab cycle. Dropped —
  # those chords now belong to the editor's word/page motion family. Tabs
  # are still cycled from inside the tab pane (Alt+Up then Left/Right).
  windowRegisterShortcut(result.window, Shortcut(
    code: int(KEYCODE_LETTER('P')), alt: true, shift: true,
    invoke: paletteLockCb, cp: nil))

  startPump(result.window)

proc applyInitialFocus*(refs: UiRefs) =
  case config.initialFocus
  of ftTree:   focusElement(addr refs.pane.e)
  of ftEditor: focusElement(addr refs.editor.e)
  of ftTerm:
    if refs.termStack != nil and refs.termStack.terms.len > 0:
      stackFocusAt(refs.termStack, config.initialTermIdx)
