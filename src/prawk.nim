import std/os
import ui, theme, font, project

proc resolveArgv() =
  if paramCount() == 0:
    project.projectRoot = getCurrentDir()
    return
  let arg = paramStr(1)
  if dirExists(arg):
    project.projectRoot = absolutePath(arg)
  elif fileExists(arg):
    project.startFile = absolutePath(arg)
    project.projectRoot = parentDir(project.startFile)
  else:
    project.projectRoot = getCurrentDir()
    project.startFile = absolutePath(arg)

initialise()
loadTheme()
loadFont()
resolveArgv()
let refs = buildUi()
if project.startFile.len > 0:
  editorOpenFile(refs.editor, project.startFile)
quit messageLoop()
