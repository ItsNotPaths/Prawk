var
  projectRoot*: string
  startFile*: string
  onProjectChange*: proc() {.closure.}

proc setProjectRoot*(path: string) =
  if path.len == 0 or path == projectRoot: return
  projectRoot = path
  if onProjectChange != nil:
    onProjectChange()
