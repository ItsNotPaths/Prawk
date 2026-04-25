import std/os
import luigi, term, project, config

type
  TerminalStack* = object
    e*: Element
    terms*: seq[ptr Terminal]
    focusIdx*: int
    scrollY*: int

var theTermStack*: ptr TerminalStack

const
  headerPadX: cint = 6
  headerPadY: cint = 3
  minTerminalRows = 6

proc glyphDims(): (cint, cint) =
  if ui.activeFont != nil:
    (ui.activeFont.glyphWidth, ui.activeFont.glyphHeight)
  else:
    (9.cint, 16.cint)

proc headerHeight(): cint =
  let (_, gH) = glyphDims()
  gH + 2 * headerPadY

proc minPerHeight(): cint =
  let (_, gH) = glyphDims()
  gH * cint(minTerminalRows)

proc stackTerminalLabel*(s: ptr TerminalStack, i: int): string =
  if s == nil or i < 0 or i >= s.terms.len: return ""
  let t = s.terms[i]
  if t != nil and t.name.len > 0: t.name
  else: "t" & $(i + 1)

proc stackPersist*(s: ptr TerminalStack) =
  if s == nil: return
  var names: seq[string] = @[]
  for t in s.terms:
    if t != nil: names.add(t.name) else: names.add("")
  config.writeSession(names)

proc layoutTerminals(s: ptr TerminalStack) =
  if s == nil or s.terms.len == 0: return
  let n = s.terms.len
  let bx0 = s.e.bounds.l
  let bx1 = s.e.bounds.r
  let by0 = s.e.bounds.t + headerHeight()
  let by1 = s.e.bounds.b
  let availH = max(cint(0), by1 - by0)
  let mh = minPerHeight()
  let evenH = if n > 0: availH div cint(n) else: cint(0)
  let perH = max(mh, evenH)
  let totalH = perH * cint(n)
  let maxScroll = max(0, int(totalH - availH))
  if s.scrollY < 0: s.scrollY = 0
  if s.scrollY > maxScroll: s.scrollY = maxScroll
  let y0 = by0 - cint(s.scrollY)
  for i in 0 ..< n:
    let t = s.terms[i]
    if t == nil: continue
    let top = y0 + cint(i) * perH
    let bot = top + perH
    elementMove(addr t.e, Rectangle(l: bx0, r: bx1, t: top, b: bot), false)

proc paintHeader(s: ptr TerminalStack, painter: ptr Painter) =
  let (gW, _) = glyphDims()
  let hH = headerHeight()
  let hRect = Rectangle(l: s.e.bounds.l, r: s.e.bounds.r,
                        t: s.e.bounds.t, b: s.e.bounds.t + hH)
  drawBlock(painter, hRect, ui.theme.panel2)
  var x: cint = s.e.bounds.l + headerPadX
  for i in 0 ..< s.terms.len:
    let label = stackTerminalLabel(s, i)
    let textW = if label.len > 0: cint(label.len) * gW else: gW
    let w = textW + 2 * headerPadX
    if x + w > s.e.bounds.r: break
    let isFocused = (i == s.focusIdx)
    let bg = if isFocused: ui.theme.selected else: ui.theme.panel2
    let fg = if isFocused: ui.theme.textSelected else: ui.theme.text
    let cell = Rectangle(l: x, r: x + w,
                         t: s.e.bounds.t + 1, b: s.e.bounds.t + hH - 1)
    drawBlock(painter, cell, bg)
    if label.len > 0:
      drawString(painter, cell, label.cstring, label.len, fg,
                 cint(ALIGN_CENTER), nil)
    x += w + 2

proc headerHitIdx(s: ptr TerminalStack, localX: cint): int =
  let (gW, _) = glyphDims()
  var x: cint = headerPadX
  for i in 0 ..< s.terms.len:
    let label = stackTerminalLabel(s, i)
    let textW = if label.len > 0: cint(label.len) * gW else: gW
    let w = textW + 2 * headerPadX
    if localX >= x and localX < x + w: return i
    x += w + 2
  -1

proc stackFocusedTerminal*(s: ptr TerminalStack): ptr Terminal =
  if s == nil or s.terms.len == 0: return nil
  if s.focusIdx < 0 or s.focusIdx >= s.terms.len: s.focusIdx = 0
  s.terms[s.focusIdx]

proc stackFocusAt*(s: ptr TerminalStack, idx: int) =
  if s == nil or s.terms.len == 0: return
  var i = idx
  if i < 0: i = 0
  if i >= s.terms.len: i = s.terms.len - 1
  s.focusIdx = i
  elementFocus(addr s.terms[i].e)
  elementRepaint(addr s.e, nil)

proc stackFocusNext*(cp: pointer) {.cdecl.} =
  let s = cast[ptr TerminalStack](cp)
  if s == nil or s.terms.len == 0: return
  s.focusIdx = (s.focusIdx + 1) mod s.terms.len
  elementFocus(addr s.terms[s.focusIdx].e)
  elementRepaint(addr s.e, nil)

proc stackFocusPrev*(cp: pointer) {.cdecl.} =
  let s = cast[ptr TerminalStack](cp)
  if s == nil or s.terms.len == 0: return
  s.focusIdx = (s.focusIdx - 1 + s.terms.len) mod s.terms.len
  elementFocus(addr s.terms[s.focusIdx].e)
  elementRepaint(addr s.e, nil)

proc stackMessage(element: ptr Element, message: Message,
                  di: cint, dp: pointer): cint {.cdecl.} =
  let s = cast[ptr TerminalStack](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    paintHeader(s, painter)
    return 0    # 0 so children still paint

  elif message == msgLayout:
    layoutTerminals(s)
    return 0

  elif message == msgMouseWheel:
    s.scrollY -= int(di) div 4
    elementRefresh(element)
    return 1

  elif message == msgLeftDown:
    let w = element.window
    if w == nil: return 0
    let ly = w.cursorY - element.bounds.t
    if ly >= 0 and ly < headerHeight():
      let lx = w.cursorX - element.bounds.l
      let hit = headerHitIdx(s, lx)
      if hit >= 0:
        stackFocusAt(s, hit)
        return 1
    return 0

  return 0

proc stackCreate*(parent: ptr Element): ptr TerminalStack =
  let e = elementCreate(csize_t(sizeof(TerminalStack)), parent,
                        ELEMENT_V_FILL or ELEMENT_H_FILL,
                        stackMessage, "TerminalStack")
  let s = cast[ptr TerminalStack](e)
  s.focusIdx = 0
  s.scrollY = 0
  theTermStack = s
  return s

proc stackAddTerminal*(s: ptr TerminalStack, name: string = ""): ptr Terminal =
  if s == nil: return nil
  let t = terminalCreate(addr s.e, ELEMENT_V_FILL or ELEMENT_H_FILL)
  if t != nil:
    t.name = name
    s.terms.add(t)
    elementRefresh(addr s.e)
  return t

proc stackKillAt*(s: ptr TerminalStack, idx: int) =
  if s == nil or idx < 0 or idx >= s.terms.len: return
  let t = s.terms[idx]
  s.terms.delete(idx)
  if s.focusIdx >= s.terms.len: s.focusIdx = s.terms.len - 1
  if s.focusIdx < 0: s.focusIdx = 0
  if t != nil: elementDestroy(addr t.e)
  elementRefresh(addr s.e)
  if s.terms.len > 0:
    elementFocus(addr s.terms[s.focusIdx].e)

proc stackNameAt*(s: ptr TerminalStack, idx: int, name: string) =
  if s == nil or idx < 0 or idx >= s.terms.len: return
  let t = s.terms[idx]
  if t == nil: return
  t.name = name
  elementRepaint(addr s.e, nil)

proc stackProjectChanged*(s: ptr TerminalStack) =
  ## Per design.md: existing terminals re-CD to new project root,
  ## processes preserved if running, otherwise fresh prompts.
  if s == nil or project.projectRoot.len == 0: return
  let cmd = "cd " & quoteShell(project.projectRoot)
  for t in s.terms:
    termRunCmd(t, cmd)

proc stackInstall*(s: ptr TerminalStack) =
  ## Wire project-change broadcast and persist on changes.
  project.registerProjectChange(proc() =
    if s != nil: stackProjectChanged(s))

proc stackNewShortcut*(cp: pointer) {.cdecl.} =
  let s = cast[ptr TerminalStack](cp)
  if s == nil: return
  let t = stackAddTerminal(s, "")
  if t != nil:
    stackFocusAt(s, s.terms.len - 1)
    stackPersist(s)

proc stackKillFocusedShortcut*(cp: pointer) {.cdecl.} =
  let s = cast[ptr TerminalStack](cp)
  if s == nil or s.terms.len == 0: return
  stackKillAt(s, s.focusIdx)
  stackPersist(s)
