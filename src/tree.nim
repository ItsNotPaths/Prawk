import std/[os, algorithm]
import luigi, project, commands, resultspane, menubar

type
  Node = object
    name: string
    path: string
    depth: int
    isDir: bool
    expanded: bool

  FolderTree = object
    nodes: seq[Node]

var
  theTreeState: FolderTree
  theTreePane: ptr ResultsPane

proc listDir(path: string, depth: int): seq[Node] =
  var dirs, files: seq[Node]
  try:
    for kind, entry in walkDir(path):
      let name = extractFilename(entry)
      let isDir = (kind == pcDir or kind == pcLinkToDir)
      let n = Node(name: name, path: entry, depth: depth, isDir: isDir)
      if isDir: dirs.add(n) else: files.add(n)
  except OSError:
    discard
  dirs.sort(proc (a, b: Node): int = cmp(a.name, b.name))
  files.sort(proc (a, b: Node): int = cmp(a.name, b.name))
  result = dirs & files

proc rebuildRoot(tr: ptr FolderTree) =
  tr.nodes.setLen(0)
  if project.projectRoot.len > 0:
    tr.nodes = listDir(project.projectRoot, 0)

proc expandAt(tr: ptr FolderTree, idx: int) =
  if idx < 0 or idx >= tr.nodes.len: return
  if not tr.nodes[idx].isDir or tr.nodes[idx].expanded: return
  let children = listDir(tr.nodes[idx].path, tr.nodes[idx].depth + 1)
  tr.nodes[idx].expanded = true
  if children.len > 0:
    tr.nodes = tr.nodes[0 .. idx] & children & tr.nodes[idx + 1 .. tr.nodes.high]

proc collapseAt(tr: ptr FolderTree, idx: int) =
  if idx < 0 or idx >= tr.nodes.len: return
  if not tr.nodes[idx].isDir or not tr.nodes[idx].expanded: return
  let myDepth = tr.nodes[idx].depth
  var j = idx + 1
  while j < tr.nodes.len and tr.nodes[j].depth > myDepth:
    inc j
  if j > idx + 1:
    tr.nodes = tr.nodes[0 .. idx] & tr.nodes[j .. tr.nodes.high]
  tr.nodes[idx].expanded = false

proc rowText(n: Node): string =
  if n.isDir:
    if n.expanded: result.add("v ")
    else:          result.add("> ")
  else:
    result.add("  ")
  for _ in 0 ..< n.depth: result.add('-')
  result.add("| ")
  result.add(n.name)
  if n.isDir and not n.expanded:
    result.add('/')

# ---------- Provider hooks ----------

proc treeRowCount(s: pointer): int {.nimcall.} =
  cast[ptr FolderTree](s).nodes.len

proc treeRowText(s: pointer, i: int): string {.nimcall.} =
  let tr = cast[ptr FolderTree](s)
  if i < 0 or i >= tr.nodes.len: ""
  else: rowText(tr.nodes[i])

proc treePaintRow(s: pointer, i: int, p: ptr Painter,
                  r: Rectangle, sel: bool) {.nimcall.} =
  let tr = cast[ptr FolderTree](s)
  if i < 0 or i >= tr.nodes.len: return
  let bg = if sel: ui.theme.selected else: ui.theme.panel1
  drawBlock(p, r, bg)
  let textColor = if sel: ui.theme.textSelected else: ui.theme.text
  let txt = rowText(tr.nodes[i])
  drawString(p, r, txt.cstring, txt.len, textColor, cint(ALIGN_LEFT), nil)

proc treeOnSelect(s: pointer, i: int) {.nimcall.} =
  let tr = cast[ptr FolderTree](s)
  if i < 0 or i >= tr.nodes.len: return
  let n = tr.nodes[i]
  if n.isDir:
    if n.expanded: collapseAt(tr, i)
    else: expandAt(tr, i)
  else:
    discard runCommand("editor.open", @[n.path])

proc treeOnContext(s: pointer, i: int) {.nimcall.} =
  let tr = cast[ptr FolderTree](s)
  if i < 0 or i >= tr.nodes.len: return
  if not tr.nodes[i].isDir: return
  openPaletteWith("project.load " & tr.nodes[i].path)

proc treeOnKey(s: pointer, code: cint, ctrl, shift: bool): bool {.nimcall.} =
  let tr = cast[ptr FolderTree](s)
  if theTreePane == nil: return false
  let pane = theTreePane
  let sel = pane.selected
  let n = tr.nodes.len

  if shift and code == int(KEYCODE_ENTER):
    if sel >= 0 and sel < n and tr.nodes[sel].isDir:
      openPaletteWith("project.load " & tr.nodes[sel].path)
    return true

  if ctrl and code == int(KEYCODE_LETTER('N')):
    if sel < n - 1: pane.selected = sel + 1
    return true
  if ctrl and code == int(KEYCODE_LETTER('P')):
    if sel > 0: pane.selected = sel - 1
    return true
  if code == int(KEYCODE_RIGHT):
    if sel >= 0 and sel < n and tr.nodes[sel].isDir and not tr.nodes[sel].expanded:
      expandAt(tr, sel)
    return true
  if code == int(KEYCODE_LEFT):
    if sel >= 0 and sel < n and tr.nodes[sel].isDir and tr.nodes[sel].expanded:
      collapseAt(tr, sel)
    return true
  false

proc treeProvider*(): Provider =
  Provider(
    state: cast[pointer](addr theTreeState),
    name: "files",
    rowCount: treeRowCount,
    rowText: treeRowText,
    onPaintRow: treePaintRow,
    onSelect: treeOnSelect,
    onContext: treeOnContext,
    onKey: treeOnKey,
    onBack: nil)

proc swapBackToTree(args: seq[string]) =
  if theTreePane == nil: return
  paneSetProvider(theTreePane, treeProvider())
  if theTreePane.e.window != nil:
    elementFocus(addr theTreePane.e)

proc treeInstall*(pane: ptr ResultsPane) =
  theTreePane = pane
  rebuildRoot(addr theTreeState)
  paneSetProvider(pane, treeProvider())
  registerCommand("files", swapBackToTree)
  registerCommand("tree", swapBackToTree)
  project.registerProjectChange(proc() =
    rebuildRoot(addr theTreeState)
    if theTreePane != nil:
      paneResetSelection(theTreePane))
