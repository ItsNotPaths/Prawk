import std/os
import ui, theme, font, project, commands, config, highlight

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
config.loadConfig()
theme.activeTheme = config.themePref
loadInitialTheme()
loadFont()
highlight.loadAllSyntaxes()
resolveArgv()
registerBuiltins()
let refs = buildUi()
if project.startFile.len > 0:
  editorOpenFile(refs.editor, project.startFile)
applyInitialFocus(refs)
quit messageLoop()
