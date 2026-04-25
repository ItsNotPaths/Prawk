import std/os
import project, editor, term

type
  CmdProc* = proc (args: seq[string]) {.closure.}
  Command* = object
    name*: string
    invoke*: CmdProc

var registry*: seq[Command]

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
  if term.theTermBottom == nil: return
  var buf = "\r\nprawk commands:\r\n"
  for c in registry:
    buf.add("  " & c.name & "\r\n")
  term.writeText(term.theTermBottom, buf)

proc registerBuiltins*() =
  registerCommand("project.load", cmdProjectLoad)
  registerCommand("project.parent", cmdProjectParent)
  registerCommand("editor.save", cmdEditorSave)
  registerCommand("quit", cmdQuit)
  registerCommand("help", cmdHelp)
