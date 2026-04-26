import luigi, editor, highlight

type
  Minimap* = object
    e*: Element
    visible*: bool
    pixels: seq[uint32]
    pixelW, pixelH: int
    lastBufPtr: pointer
    lastDirtyFrom: int
    lastLines: int
    step: int                # source rows per minimap row (>=1)
    spans: seq[Span]

const
  minimapWidth*: cint  = 80   # px wide; one source column per pixel
  minimapRowH:   int   = 2
  fixedWidthPad: cint  = 2    # gap between editor and minimap

var theMinimap*: ptr Minimap

proc isVisible*(mm: ptr Minimap): bool =
  mm != nil and mm.visible

proc brighten(c: uint32, amt: float = 0.30): uint32 {.inline.} =
  let r = int((c shr 16) and 0xFF)
  let g = int((c shr 8) and 0xFF)
  let b = int(c and 0xFF)
  let nr = min(255, r + int(float(255 - r) * amt))
  let ng = min(255, g + int(float(255 - g) * amt))
  let nb = min(255, b + int(float(255 - b) * amt))
  uint32((nr shl 16) or (ng shl 8) or nb)

proc rebuild(mm: ptr Minimap, ed: ptr Editor) =
  let buf = activeBuf(ed)
  if buf == nil: return
  let pw = mm.pixelW
  let ph = mm.pixelH
  if pw <= 0 or ph <= 0: return
  if mm.pixels.len != pw * ph:
    mm.pixels.setLen(pw * ph)

  let lines = bufLines(buf)
  let n = lines.len
  let bg = ui.theme.codeBackground
  for i in 0 ..< mm.pixels.len: mm.pixels[i] = bg
  if n == 0:
    mm.step = 1
    return

  let mmRows = ph div minimapRowH
  let step = max(1, (n + mmRows - 1) div mmRows)
  mm.step = step

  # Refresh tokenizer carry-state up to the last source row we'll touch so
  # block-comment continuation across sampled rows still colors correctly.
  let lastSrc = min(n - 1, (mmRows - 1) * step)
  bufRefreshStates(ed, lastSrc)
  let states = bufLineStartStates(buf)
  let syntax = bufSyntax(buf)

  var mmy = 0
  var src = 0
  while mmy < mmRows and src < n:
    let entry = if src < states[].len: states[][src] else: 0'u8
    discard tokenizeLine(lines[src], syntax, entry, mm.spans)
    let baseY = mmy * minimapRowH
    # bg-prefilled; only write spans we actually have, default-color text fills
    # the gaps left as bg (cheaper than writing default for every char).
    for s in mm.spans:
      let color = colorFor(s.kind)
      let c0 = s.col
      let c1 = min(c0 + s.n, pw)
      if c0 >= pw: continue
      for c in c0 ..< c1:
        for dy in 0 ..< minimapRowH:
          mm.pixels[(baseY + dy) * pw + c] = color
    inc mmy
    src += step

  mm.lastBufPtr = cast[pointer](buf)
  mm.lastDirtyFrom = bufDirtyFromRow(buf)
  mm.lastLines = n

proc maybeRebuild(mm: ptr Minimap, ed: ptr Editor) =
  let buf = activeBuf(ed)
  if buf == nil: return
  let bw = int(mm.e.bounds.r - mm.e.bounds.l)
  let bh = int(mm.e.bounds.b - mm.e.bounds.t)
  let needW = min(int(minimapWidth), bw)
  if needW <= 0 or bh <= 0: return
  let dirty =
    cast[pointer](buf) != mm.lastBufPtr or
    mm.pixelW != needW or mm.pixelH != bh or
    bufDirtyFromRow(buf) < mm.lastDirtyFrom or
    bufLines(buf).len != mm.lastLines
  if dirty:
    mm.pixelW = needW
    mm.pixelH = bh
    rebuild(mm, ed)

proc paintBlit(mm: ptr Minimap, p: ptr Painter, ed: ptr Editor) =
  let pw = mm.pixelW
  let ph = mm.pixelH
  if pw <= 0 or ph <= 0: return
  let fb = painterPixels(p)
  let stride = int(p.width)
  let clip = p.clip
  let baseX = int(mm.e.bounds.l)
  let baseY = int(mm.e.bounds.t)

  # Blit cache to framebuffer, clipped against painter.clip.
  for py in 0 ..< ph:
    let dy = baseY + py
    if dy < int(clip.t) or dy >= int(clip.b): continue
    let rowOff = dy * stride
    let srcOff = py * pw
    for px in 0 ..< pw:
      let dx = baseX + px
      if dx < int(clip.l) or dx >= int(clip.r): continue
      fb[rowOff + dx] = mm.pixels[srcOff + px]

  # Brightened viewport band — read back from framebuffer, blend, write.
  let buf = activeBuf(ed)
  if buf == nil: return
  let n = bufLines(buf).len
  if n == 0: return
  let topSrc = bufTopLine(buf)
  let visSrc = bufVisibleRows(ed)
  let step = max(1, mm.step)
  let bandTopMm = (topSrc div step) * minimapRowH
  let bandBotMm = min(ph, ((topSrc + visSrc + step - 1) div step) * minimapRowH)
  if bandBotMm <= bandTopMm: return
  for py in bandTopMm ..< bandBotMm:
    let dy = baseY + py
    if dy < int(clip.t) or dy >= int(clip.b): continue
    let rowOff = dy * stride
    for px in 0 ..< pw:
      let dx = baseX + px
      if dx < int(clip.l) or dx >= int(clip.r): continue
      fb[rowOff + dx] = brighten(fb[rowOff + dx])

proc clickToScroll(mm: ptr Minimap, ed: ptr Editor, mouseY: cint) =
  let buf = activeBuf(ed)
  if buf == nil: return
  let mmY = int(mouseY - mm.e.bounds.t)
  if mmY < 0: return
  let step = max(1, mm.step)
  let srcRow = (mmY div minimapRowH) * step
  let visSrc = bufVisibleRows(ed)
  bufSetTopLine(ed, srcRow - visSrc div 2)
  elementRepaint(addr ed.e, nil)
  elementRepaint(addr mm.e, nil)

proc minimapMessage(element: ptr Element, message: Message,
                    di: cint, dp: pointer): cint {.cdecl.} =
  let mm = cast[ptr Minimap](element)
  let ed = theEditor
  if message == msgPaint:
    if not mm.visible or ed == nil: return 0
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.codeBackground)
    maybeRebuild(mm, ed)
    paintBlit(mm, painter, ed)
    return 0

  elif message == msgGetWidth:
    return if mm.visible: minimapWidth + fixedWidthPad else: cint(0)

  elif message == msgLayout:
    return 0

  elif message == msgLeftDown:
    if not mm.visible or ed == nil: return 0
    let w = element.window
    if w == nil: return 0
    clickToScroll(mm, ed, w.cursorY)
    return 1

  elif message == msgMouseDrag:
    if not mm.visible or ed == nil: return 0
    let w = element.window
    if w == nil: return 0
    clickToScroll(mm, ed, w.cursorY)
    return 1

  return 0

proc minimapCreate*(parent: ptr Element): ptr Minimap =
  let e = elementCreate(csize_t(sizeof(Minimap)), parent,
                        ELEMENT_V_FILL,
                        minimapMessage, "Minimap")
  let mm = cast[ptr Minimap](e)
  mm.visible = true
  mm.lastDirtyFrom = high(int)
  mm.lastBufPtr = nil
  theMinimap = mm
  return mm

proc minimapSetVisible*(mm: ptr Minimap, on: bool) =
  if mm == nil: return
  mm.visible = on
  # Force the parent panel to re-run layout so the editor reclaims/yields
  # the minimap's column.
  if mm.e.parent != nil:
    elementRefresh(mm.e.parent)
  else:
    elementRepaint(addr mm.e, nil)

proc minimapToggle*(mm: ptr Minimap) =
  if mm == nil: return
  minimapSetVisible(mm, not mm.visible)
