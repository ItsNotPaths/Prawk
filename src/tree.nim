import std/[os, algorithm]
import luigi, project

type
  Node = object
    name: string
    path: string
    depth: int
    isDir: bool
    expanded: bool

  FolderTree* = object
    e*: Element
    nodes: seq[Node]
    topLine: int
    selected: int

proc glyphDims(): (cint, cint) =
  if ui.activeFont != nil:
    (ui.activeFont.glyphWidth, ui.activeFont.glyphHeight)
  else:
    (9.cint, 16.cint)

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
  tr.topLine = 0
  tr.selected = 0

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

proc chevron(n: Node): cstring =
  if n.isDir:
    if n.expanded: cstring"v " else: cstring"> "
  else:
    cstring"  "

proc visibleRows(tr: ptr FolderTree): int =
  let (_, gH) = glyphDims()
  max(1, int(tr.e.bounds.b - tr.e.bounds.t) div max(1, int(gH)))

proc followSelection(tr: ptr FolderTree) =
  let vr = visibleRows(tr)
  if tr.selected < tr.topLine:
    tr.topLine = tr.selected
  elif tr.selected >= tr.topLine + vr:
    tr.topLine = tr.selected - vr + 1
  if tr.topLine < 0: tr.topLine = 0

proc treeMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let tr = cast[ptr FolderTree](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    let (gW, gH) = glyphDims()
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let bx = element.bounds.l
    let by = element.bounds.t
    let vr = visibleRows(tr)
    for i in 0 ..< vr:
      let idx = tr.topLine + i
      if idx >= tr.nodes.len: break
      let n = tr.nodes[idx]
      let y = by + cint(i) * gH
      let rowRect = Rectangle(l: bx, r: element.bounds.r, t: y, b: y + gH)
      if idx == tr.selected:
        drawBlock(painter, rowRect, ui.theme.selected)
      let indent = cint(n.depth) * 2 * gW
      let chevRect = Rectangle(l: bx + indent, r: bx + indent + 2 * gW, t: y, b: y + gH)
      let textColor = if idx == tr.selected: ui.theme.textSelected else: ui.theme.text
      drawString(painter, chevRect, chevron(n), castInt, textColor, cint(ALIGN_LEFT), nil)
      let nameRect = Rectangle(l: bx + indent + 2 * gW, r: element.bounds.r, t: y, b: y + gH)
      drawString(painter, nameRect, n.name.cstring, cast[pointer](n.name.len),
                 textColor, cint(ALIGN_LEFT), nil)
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, element.bounds, 0x9253be'u32,
                 Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgLeftDown:
    elementFocus(element)
    let (_, gH) = glyphDims()
    let w = element.window
    if w != nil:
      let ly = w.cursorY - element.bounds.t
      let idx = tr.topLine + int(ly div max(1, gH))
      if idx >= 0 and idx < tr.nodes.len:
        tr.selected = idx
        if tr.nodes[idx].isDir:
          if tr.nodes[idx].expanded: collapseAt(tr, idx)
          else: expandAt(tr, idx)
      elementRepaint(element, nil)
    return 1

  elif message == msgMouseWheel:
    let vr = visibleRows(tr)
    tr.topLine += int(di) div 60
    if tr.topLine < 0: tr.topLine = 0
    let maxTop = max(0, tr.nodes.len - vr)
    if tr.topLine > maxTop: tr.topLine = maxTop
    elementRepaint(element, nil)
    return 1

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if w != nil and w.alt: return 0
    let code = k.code
    let ctrl = (w != nil and w.ctrl)
    if code == int(KEYCODE_DOWN) or (ctrl and code == int(KEYCODE_LETTER('N'))):
      if tr.selected < tr.nodes.len - 1: inc tr.selected
    elif code == int(KEYCODE_UP) or (ctrl and code == int(KEYCODE_LETTER('P'))):
      if tr.selected > 0: dec tr.selected
    elif code == int(KEYCODE_RIGHT) or code == int(KEYCODE_ENTER):
      if tr.selected >= 0 and tr.selected < tr.nodes.len and tr.nodes[tr.selected].isDir:
        expandAt(tr, tr.selected)
    elif code == int(KEYCODE_LEFT):
      if tr.selected >= 0 and tr.selected < tr.nodes.len and
         tr.nodes[tr.selected].isDir and tr.nodes[tr.selected].expanded:
        collapseAt(tr, tr.selected)
    else:
      return 0
    followSelection(tr)
    elementRepaint(element, nil)
    return 1

  return 0

proc treeCreate*(parent: ptr Element, flags: uint32 = 0): ptr FolderTree =
  let e = elementCreate(csize_t(sizeof(FolderTree)), parent, flags or ELEMENT_TAB_STOP,
                        treeMessage, "FolderTree")
  let tr = cast[ptr FolderTree](e)
  rebuildRoot(tr)
  return tr
