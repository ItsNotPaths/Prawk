import std/[os, strutils]
import luigi, project, editor, terminalstack, theme, config, minimap
when defined(termDebug):
  import term

type
  CmdProc* = proc (args: seq[string]) {.closure.}
  Command* = object
    name*: string
    invoke*: CmdProc

var
  registry*: seq[Command]
  openPaletteWithCb*: proc(text: string) {.closure.}
  clDispatchCb*: proc(line: string) {.closure.}
  clShellCwdCb*: proc(): string {.closure.}
  treeRefreshCb*: proc() {.closure.}

proc registerCommand*(name: string, p: CmdProc) =
  for i in 0 ..< registry.len:
    if registry[i].name == name:
      registry[i].invoke = p
      return
  registry.add(Command(name: name, invoke: p))

proc runCommand*(name: string, args: seq[string] = @[]): bool =
  for c in registry:
    if c.name == name:
      c.invoke(args)
      return true
  return false

proc cmdTerminalUpdate(args: seq[string]) =
  ## Broadcasts a target dir to unlocked terminals + tree + git pane by
  ## calling project.setProjectRoot (which fires the registered handlers).
  ## With a path arg: targets that path. Without: reads the master CL
  ## shell's actual cwd via /proc/<pid>/cwd, so the user can `cd ../foo`
  ## in CL and then `:tu` to sync everything else.
  var target = ""
  if args.len >= 1:
    target = args[0]
    if not isAbsolute(target):
      let base = if project.projectRoot.len > 0: project.projectRoot
                 else: getCurrentDir()
      target = base / target
    try: target = absolutePath(target).normalizedPath
    except OSError, ValueError: return
  elif clShellCwdCb != nil:
    target = clShellCwdCb()
  if target.len == 0 or not dirExists(target): return
  project.setProjectRoot(target)

proc cmdEditorSave(args: seq[string]) =
  if editor.theEditor != nil:
    saveCurrent(editor.theEditor)

proc cmdEditorCopy(args: seq[string]) =
  if editor.theEditor != nil:
    editorCopySelection(editor.theEditor)

proc cmdEditorPaste(args: seq[string]) =
  if editor.theEditor != nil:
    editorPasteAtCursor(editor.theEditor)

proc cmdEditorUndo(args: seq[string]) =
  if editor.theEditor != nil:
    editorUndo(editor.theEditor)

proc cmdEditorRedo(args: seq[string]) =
  if editor.theEditor != nil:
    editorRedo(editor.theEditor)

proc cmdWindowFullscreen(args: seq[string]) =
  ## Toggle _NET_WM_STATE_FULLSCREEN on the first non-menu window. luigi
  ## doesn't expose its own fullscreen API; this routes through X11 directly.
  var w = cast[ptr Window](ui.windows)
  while w != nil:
    if (w.e.flags and WINDOW_MENU) == 0:
      windowToggleFullscreen(w)
      return
    w = w.next

proc cmdQuit(args: seq[string]) =
  quit(0)

proc cmdEditorOpen(args: seq[string]) =
  if args.len < 1: return
  let p = args[0]
  if not fileExists(p): return
  if editor.theEditor != nil:
    editor.editorOpenFile(editor.theEditor, p)

proc cmdEditorOpenForce(args: seq[string]) =
  if args.len < 1: return
  editor.editorForceOpenFile(args[0])

proc cmdJump(args: seq[string]) =
  if args.len < 1 or editor.theEditor == nil: return
  let raw = args[0].strip()
  if raw.len == 0: return
  try:
    if raw[0] == '+':
      editorJumpRelative(editor.theEditor,  parseInt(raw[1 .. ^1]))
    elif raw[0] == '-':
      editorJumpRelative(editor.theEditor, -parseInt(raw[1 .. ^1]))
    else:
      editorJumpAbsolute(editor.theEditor,  parseInt(raw))
  except ValueError:
    discard

proc cmdTabNext(args: seq[string]) =
  if editor.theEditor != nil: editorTabNext(editor.theEditor)

proc cmdTabPrev(args: seq[string]) =
  if editor.theEditor != nil: editorTabPrev(editor.theEditor)

proc cmdTabClose(args: seq[string]) =
  ## 1-based idx to match the strip's visual order.
  if editor.theEditor == nil: return
  let ed = editor.theEditor
  var idx = editorActiveIdx(ed)
  if args.len >= 1:
    try: idx = parseInt(args[0]) - 1
    except ValueError: return
  if idx < 0 or idx >= editorTabCount(ed): return
  if editorTabIsDirty(ed, idx):
    if openPaletteWithCb != nil:
      openPaletteWithCb("tab.close.force " & $(idx + 1))
    return
  editorCloseTab(ed, idx)

proc cmdTabCloseForce(args: seq[string]) =
  if editor.theEditor == nil: return
  let ed = editor.theEditor
  var idx = editorActiveIdx(ed)
  if args.len >= 1:
    try: idx = parseInt(args[0]) - 1
    except ValueError: return
  editorTabCloseForce(ed, idx)

proc cmdTermNew(args: seq[string]) =
  if theTermStack == nil: return
  let name = if args.len >= 1: args[0] else: ""
  let t = stackAddTerminal(theTermStack, name)
  if t != nil:
    stackFocusAt(theTermStack, theTermStack.terms.len - 1)
    stackPersist(theTermStack)

proc cmdTermKill(args: seq[string]) =
  ## 1-based idx to match the t1/t2/... title bars.
  if theTermStack == nil or args.len < 1: return
  var idx = -1
  try: idx = parseInt(args[0]) - 1
  except ValueError: return
  if idx < 0 or idx >= theTermStack.terms.len: return
  stackKillAt(theTermStack, idx)
  stackPersist(theTermStack)

proc cmdTermName(args: seq[string]) =
  if theTermStack == nil or args.len < 2: return
  var idx = -1
  try: idx = parseInt(args[0]) - 1
  except ValueError: return
  if idx < 0 or idx >= theTermStack.terms.len: return
  stackNameAt(theTermStack, idx, args[1])
  stackPersist(theTermStack)

proc cmdLock(args: seq[string]) =
  if theTermStack == nil or args.len < 1: return
  var s = args[0].strip()
  if s.len == 0: return
  if s[0] in {'t', 'T'} and s.len > 1: s = s[1 .. ^1]
  var idx = -1
  try: idx = parseInt(s) - 1
  except ValueError: return
  stackLockToggle(theTermStack, idx)

proc cmdTheme(args: seq[string]) =
  if args.len < 1: return
  if theme.loadThemeByName(args[0]):
    config.setConfigKey("theme", args[0])
    theme.repaintAllWindows()

when defined(termDebug):
  proc cmdTermDebugDump(args: seq[string]) =
    ## Snapshot the focused (or args[0]-indexed, 1-based) terminal's libtmt
    ## grid to /tmp/prawk-term-N.grid. Only registered in -d:termDebug builds.
    if theTermStack == nil or theTermStack.terms.len == 0: return
    var idx = theTermStack.focusIdx
    if args.len >= 1:
      var s = args[0].strip()
      if s.len > 0 and s[0] in {'t','T'}: s = s[1 .. ^1]
      try: idx = parseInt(s) - 1
      except ValueError: return
    if idx < 0 or idx >= theTermStack.terms.len: return
    termDebugDump(theTermStack.terms[idx])

proc cmdMinimap(args: seq[string]) =
  ## `:minimap` toggles. `:minimap on|off` sets explicitly. Persists to config.
  let mm = theMinimap
  if mm == nil: return
  var on = not mm.visible
  if args.len >= 1:
    case args[0].toLowerAscii
    of "on", "true", "1", "yes":  on = true
    of "off", "false", "0", "no": on = false
    of "toggle":                  on = not mm.visible
    else: return
  minimapSetVisible(mm, on)
  config.minimapEnabled = on
  config.setConfigKey("minimap", if on: "on" else: "off")

proc registerBuiltins*() =
  registerCommand("terminal.update", cmdTerminalUpdate)
  registerCommand("tu", cmdTerminalUpdate)
  registerCommand("editor.save", cmdEditorSave)
  registerCommand("editor.open", cmdEditorOpen)
  registerCommand("editor.open.force", cmdEditorOpenForce)
  registerCommand("editor.copy", cmdEditorCopy)
  registerCommand("editor.paste", cmdEditorPaste)
  registerCommand("editor.undo", cmdEditorUndo)
  registerCommand("editor.redo", cmdEditorRedo)
  registerCommand("window.fullscreen", cmdWindowFullscreen)
  registerCommand("quit", cmdQuit)
  registerCommand("term.new", cmdTermNew)
  registerCommand("term.kill", cmdTermKill)
  registerCommand("term.name", cmdTermName)
  registerCommand("lock", cmdLock)
  registerCommand("termlock", cmdLock)
  registerCommand("theme", cmdTheme)
  registerCommand("jump", cmdJump)
  registerCommand("j", cmdJump)
  registerCommand("tab.next", cmdTabNext)
  registerCommand("tab.prev", cmdTabPrev)
  registerCommand("tab.close", cmdTabClose)
  registerCommand("tab.close.force", cmdTabCloseForce)
  registerCommand("minimap", cmdMinimap)
  when defined(termDebug):
    registerCommand("term.debug.dump", cmdTermDebugDump)
