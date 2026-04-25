import std/[os, strutils]
import project, editor, term, terminalstack

type
  CmdProc* = proc (args: seq[string]) {.closure.}
  Command* = object
    name*: string
    invoke*: CmdProc

var
  registry*: seq[Command]
  openPaletteWithCb*: proc(text: string) {.closure.}

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

proc cmdProjectLoad(args: seq[string]) =
  if args.len < 1: return
  let path = absolutePath(args[0])
  if dirExists(path):
    project.setProjectRoot(path)

proc cmdProjectParent(args: seq[string]) =
  if project.projectRoot.len == 0: return
  let parent = parentDir(project.projectRoot)
  if parent.len > 0 and parent != project.projectRoot:
    project.setProjectRoot(parent)

proc cmdEditorSave(args: seq[string]) =
  if editor.theEditor != nil:
    saveCurrent(editor.theEditor)

proc cmdQuit(args: seq[string]) =
  quit(0)

proc cmdHelp(args: seq[string]) =
  # TODO Pass 5: route :help output to results pane
  let t = stackFocusedTerminal(theTermStack)
  if t == nil: return
  var buf = "\r\nprawk commands:\r\n"
  for c in registry:
    buf.add("  " & c.name & "\r\n")
  termWrite(t, buf)

proc cmdEditorOpen(args: seq[string]) =
  if args.len < 1: return
  let p = args[0]
  if not fileExists(p): return
  if editor.editorIsDirty():
    if openPaletteWithCb != nil:
      openPaletteWithCb(":editor.open.force " & p)
  elif editor.theEditor != nil:
    editor.editorOpenFile(editor.theEditor, p)

proc cmdEditorOpenForce(args: seq[string]) =
  if args.len < 1: return
  editor.editorForceOpenFile(args[0])

proc cmdTermNew(args: seq[string]) =
  if theTermStack == nil: return
  let name = if args.len >= 1: args[0] else: ""
  let t = stackAddTerminal(theTermStack, name)
  if t != nil:
    stackFocusAt(theTermStack, theTermStack.terms.len - 1)
    stackPersist(theTermStack)

proc cmdTermKill(args: seq[string]) =
  if theTermStack == nil or args.len < 1: return
  var idx = -1
  try: idx = parseInt(args[0])
  except ValueError: return
  if idx < 0 or idx >= theTermStack.terms.len: return
  stackKillAt(theTermStack, idx)
  stackPersist(theTermStack)

proc cmdTermName(args: seq[string]) =
  if theTermStack == nil or args.len < 2: return
  var idx = -1
  try: idx = parseInt(args[0])
  except ValueError: return
  if idx < 0 or idx >= theTermStack.terms.len: return
  stackNameAt(theTermStack, idx, args[1])
  stackPersist(theTermStack)

proc registerBuiltins*() =
  registerCommand("project.load", cmdProjectLoad)
  registerCommand("project.parent", cmdProjectParent)
  registerCommand("editor.save", cmdEditorSave)
  registerCommand("editor.open", cmdEditorOpen)
  registerCommand("editor.open.force", cmdEditorOpenForce)
  registerCommand("quit", cmdQuit)
  registerCommand("help", cmdHelp)
  registerCommand("term.new", cmdTermNew)
  registerCommand("term.kill", cmdTermKill)
  registerCommand("term.name", cmdTermName)
