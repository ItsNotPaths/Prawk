import config

var
  projectRoot*: string
  startFile*: string
  projectChangeHandlers: seq[proc() {.closure.}]

proc registerProjectChange*(p: proc() {.closure.}) =
  projectChangeHandlers.add(p)

proc setProjectRoot*(path: string) =
  if path.len == 0 or path == projectRoot: return
  projectRoot = path
  config.pushRecent("recents.projects", path)
  for h in projectChangeHandlers: h()
