## Pass 8 — git pane (bottom half of the sidebar).
##
## Layout: branch tabs strip / status section / log section. One custom
## element with manual layout. Tab click switches the log view; the asterisk
## tracks the actually-checked-out branch (only changes via `git checkout`,
## not via tab click). Read-only-ish — visualize, don't actuate.

import std/[os, osproc, strutils, streams, times]
import luigi, font, project, editor, commands, theme

# editortabs.tabsHeight gives us a matching strip height; importing the
# module is cheap and keeps the look consistent.
import editortabs

type
  StatusEntry* = object
    code*: string     # "M ", "A ", "??", etc — width-2 padded
    path*: string

  CommitEntry* = object
    hash*: string
    author*: string
    subject*: string
    files*: seq[string]
    filesLoaded*: bool
    expanded*: bool

  GitSection* = enum gsStatus, gsLog

  GitPane* = object
    e*: Element
    branches*: seq[string]
    currentBranch*: string     # actually checked-out (asterisk follows this)
    selectedBranch*: string    # log view filter (tab click)
    status*: seq[StatusEntry]
    commits*: seq[CommitEntry]
    statusSelected*, statusTopLine*: int
    logSelected*, logTopLine*: int   # logSelected is in *flat row* space
    focused*: GitSection
    isGitRepo*: bool
    cachedHEAD*, cachedIndex*, cachedBranchTip*: Time
    cachedDotGit*: Time
    branchScroll*: cint        # horizontal pixel scroll for tab strip
    lastToggleMs*: float       # epochTime() of last commit toggle
    lastToggleHash*: string    # which commit was last toggled

var theGitPane*: ptr GitPane

# ---------- shell-out helpers --------------------------------------------

proc runGit(args: openArray[string]): tuple[ok: bool, output: string] =
  if project.projectRoot.len == 0:
    return (false, "")
  try:
    let p = startProcess("git", args = @args, workingDir = project.projectRoot,
                         options = {poUsePath, poStdErrToStdOut})
    let body = p.outputStream.readAll()
    let code = p.waitForExit()
    return (code == 0, body)
  except CatchableError:
    return (false, "")

proc dotGitDir(): string =
  if project.projectRoot.len == 0: ""
  else: project.projectRoot / ".git"

proc detectGitRepo(): bool =
  let g = dotGitDir()
  g.len > 0 and dirExists(g)

proc loadBranches(g: ptr GitPane) =
  g.branches.setLen(0)
  let (ok, body) = runGit(["branch", "--format=%(refname:short)"])
  if not ok: return
  for raw in body.splitLines():
    let s = raw.strip()
    if s.len > 0: g.branches.add(s)

proc loadCurrentBranch(g: ptr GitPane) =
  let (ok, body) = runGit(["branch", "--show-current"])
  if ok:
    g.currentBranch = body.strip()
  else:
    g.currentBranch = ""

proc loadStatus(g: ptr GitPane) =
  g.status.setLen(0)
  # --porcelain=v1 keeps the parsing trivial: 2-char code, space, path.
  # v2 is more structured but we don't need rename details for read-only.
  let (ok, body) = runGit(["status", "--porcelain"])
  if not ok: return
  for raw in body.splitLines():
    if raw.len < 4: continue
    let code = raw[0 .. 1]
    let path = raw[3 .. ^1].strip(chars = {'"'})
    g.status.add(StatusEntry(code: code, path: path))

proc loadLog(g: ptr GitPane) =
  g.commits.setLen(0)
  let branch = if g.selectedBranch.len > 0: g.selectedBranch else: "HEAD"
  let (ok, body) = runGit(["log", "-n", "50",
                          "--pretty=format:%h%x09%an%x09%s", branch])
  if not ok: return
  for raw in body.splitLines():
    let line = raw
    if line.len == 0: continue
    let parts = line.split('\t', 2)
    if parts.len < 3: continue
    g.commits.add(CommitEntry(hash: parts[0], author: parts[1],
                              subject: parts[2]))

proc loadCommitFiles(g: ptr GitPane, idx: int) =
  if idx < 0 or idx >= g.commits.len: return
  if g.commits[idx].filesLoaded: return
  let h = g.commits[idx].hash
  let (ok, body) = runGit(["show", "--name-only", "--pretty=format:", h])
  if ok:
    var files: seq[string] = @[]
    for raw in body.splitLines():
      let s = raw.strip()
      if s.len > 0: files.add(s)
    g.commits[idx].files = files
  g.commits[idx].filesLoaded = true

# ---------- mtime helpers (used by refresh + poll) -----------------------

proc statTime(p: string): Time =
  try:
    if fileExists(p) or dirExists(p): return getLastModificationTime(p)
  except OSError, IOError: discard
  Time()

proc snapshotCaches(g: ptr GitPane, dot: string) =
  ## Captures mtimes AFTER a refresh has run. gitPaneRefresh shells out to
  ## `git status` / `git log` etc., and `git status` rewrites `.git/index`
  ## (atomic temp+rename) which bumps the parent dir's mtime too. If we
  ## sampled before the refresh, the next poll would see those self-induced
  ## changes and refresh again forever. Always snapshot after.
  g.cachedDotGit     = statTime(dot)
  g.cachedHEAD       = statTime(dot / "HEAD")
  g.cachedIndex      = statTime(dot / "index")
  g.cachedBranchTip  =
    if g.currentBranch.len > 0:
      statTime(dot / "refs" / "heads" / g.currentBranch)
    else: Time()

# ---------- refresh / project change -------------------------------------

proc gitPaneRefresh*() =
  let g = theGitPane
  if g == nil: return
  g.isGitRepo = detectGitRepo()
  if not g.isGitRepo:
    g.branches.setLen(0); g.status.setLen(0); g.commits.setLen(0)
    elementRepaint(addr g.e, nil)
    return
  loadCurrentBranch(g)
  loadBranches(g)
  if g.selectedBranch.len == 0 or g.selectedBranch notin g.branches:
    g.selectedBranch = g.currentBranch
  loadStatus(g)
  loadLog(g)
  # Drop expansion state — hashes may have shifted on rebase / amend.
  for c in g.commits.mitems:
    c.expanded = false
    c.filesLoaded = false
    c.files.setLen(0)
  if g.statusSelected >= g.status.len: g.statusSelected = max(0, g.status.len - 1)
  if g.logSelected >= g.commits.len: g.logSelected = max(0, g.commits.len - 1)
  elementRepaint(addr g.e, nil)

proc onProjectChange() =
  let g = theGitPane
  if g == nil: return
  g.statusSelected = 0; g.statusTopLine = 0
  g.logSelected = 0;    g.logTopLine = 0
  g.selectedBranch = ""
  gitPaneRefresh()
  snapshotCaches(g, dotGitDir())

# ---------- mtime polling (called from pump) -----------------------------

proc gitPaneTickPoll*() =
  let g = theGitPane
  if g == nil or project.projectRoot.len == 0: return
  let dot = dotGitDir()
  let dotT = statTime(dot)
  let nowGit = dotT != Time()
  if nowGit != g.isGitRepo:
    gitPaneRefresh()
    snapshotCaches(g, dot)
    return
  if not g.isGitRepo: return
  let head = statTime(dot / "HEAD")
  let idx  = statTime(dot / "index")
  let tip =
    if g.currentBranch.len > 0:
      statTime(dot / "refs" / "heads" / g.currentBranch)
    else: Time()
  if head != g.cachedHEAD or idx != g.cachedIndex or tip != g.cachedBranchTip:
    gitPaneRefresh()
    snapshotCaches(g, dot)

# ---------- log row flattening -------------------------------------------

type LogRow = object
  isCommit: bool
  commitIdx: int          # which commit
  fileIdx: int            # only meaningful when not isCommit; index into files

proc flatLogRows(g: ptr GitPane): seq[LogRow] =
  result = @[]
  for ci in 0 ..< g.commits.len:
    result.add(LogRow(isCommit: true, commitIdx: ci, fileIdx: -1))
    if g.commits[ci].expanded:
      for fi in 0 ..< g.commits[ci].files.len:
        result.add(LogRow(isCommit: false, commitIdx: ci, fileIdx: fi))

# ---------- layout zones -------------------------------------------------

type Zones = object
  tabsR, statusR, logR, dividerR: Rectangle

proc zonesOf(g: ptr GitPane): Zones =
  let b = g.e.bounds
  let tH = tabsHeight()
  result.tabsR = Rectangle(l: b.l, r: b.r, t: b.t, b: b.t + tH)
  let bodyTop = b.t + tH
  let bodyH = max(cint(0), b.b - bodyTop)
  let halfH = bodyH div 2
  result.statusR  = Rectangle(l: b.l, r: b.r, t: bodyTop, b: bodyTop + halfH)
  result.dividerR = Rectangle(l: b.l, r: b.r,
                              t: bodyTop + halfH,
                              b: bodyTop + halfH + 1)
  result.logR     = Rectangle(l: b.l, r: b.r,
                              t: bodyTop + halfH + 1, b: b.b)

proc visibleRowsIn(rect: Rectangle, gH: cint): int =
  max(1, int(rect.b - rect.t) div max(1, int(gH)))

# ---------- diff tab opening ---------------------------------------------

proc rewriteHunkHeader(line: string): tuple[header, ctx: string] =
  ## "@@ -X,Y +A,B @@[ trailing]"  →
  ##   header = "## | -X, Y | +A, B |"
  ##   ctx    = ""    or   "<function-context tag>"
  ## Caller inserts the visual layout (blank between header and ctx etc).
  if not line.startsWith("@@ "): return (line, "")
  let closeIdx = line.find(" @@", start = 3)
  if closeIdx < 0: return (line, "")
  let mid = line[3 ..< closeIdx]
  let tail = line[closeIdx + 3 .. ^1].strip()
  let space = mid.find(' ')
  if space < 0: return (line, "")
  let oldRange = mid[0 ..< space].replace(",", ", ")
  let newRange = mid[space + 1 .. ^1].replace(",", ", ")
  return ("## | " & oldRange & " | " & newRange & " |", tail)

proc formatDiffOutput(raw: string): string =
  ## Pads section boundaries with a `\n=-=-=-=\n` bar and rewrites hunk
  ## headers (see rewriteHunkHeader). Pure presentation — the raw
  ## `git show` / `git diff` text otherwise stacks file headers, index
  ## meta, and consecutive hunks with no gap.
  const barLine = "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
  result = newStringOfCap(raw.len + 512)
  template separator() =
    result.add("\n")          # blank line above bar
    result.add(barLine)
    result.add("\n\n")        # blank line below bar
  let lines = raw.splitLines()
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("@@"):
      # Bar before every hunk header — including the first in each file,
      # which puts the divider just below `+++ b/<path>` so the file
      # header block stays grouped above the divider.
      separator()
      let (hdr, ctx) = rewriteHunkHeader(line)
      result.add(hdr)
      result.add("\n\n")          # always exactly one blank below the bar
      if ctx.len > 0:
        result.add(ctx)
        result.add('\n')          # ctx line, then content directly
      inc i
      continue
    result.add(line)
    result.add('\n')
    inc i
  if result.len > 0 and result[^1] == '\n':
    result.setLen(result.len - 1)


proc openCommitFileDiff(g: ptr GitPane, ci, fi: int) =
  if ci < 0 or ci >= g.commits.len: return
  let c = g.commits[ci]
  if fi < 0 or fi >= c.files.len: return
  let path = c.files[fi]
  let (ok, body) = runGit(["show", c.hash, "--", path])
  let synth = "diff://" & c.hash & "/" & path
  if editor.theEditor != nil:
    if ok:
      editorOpenSynthetic(editor.theEditor, synth, formatDiffOutput(body))
    else:
      editorOpenSynthetic(editor.theEditor, synth,
                          "(git show failed for " & c.hash & " " & path & ")")

proc openWorkingDiff(g: ptr GitPane, idx: int) =
  if idx < 0 or idx >= g.status.len: return
  let path = g.status[idx].path
  let (ok, body) = runGit(["diff", "--", path])
  let synth = "diff://WORKING/" & path
  if editor.theEditor != nil:
    if ok:
      editorOpenSynthetic(editor.theEditor, synth,
                          if body.len == 0: "(no diff — file may be untracked or already staged)"
                          else: formatDiffOutput(body))
    else:
      editorOpenSynthetic(editor.theEditor, synth,
                          "(git diff failed for " & path & ")")

# ---------- paint --------------------------------------------------------

proc tabRects(g: ptr GitPane, tabsR: Rectangle): seq[Rectangle] =
  result = @[]
  let (gW, _) = glyphDims()
  var x: cint = tabsR.l - g.branchScroll
  for name in g.branches:
    # Each tab: optional "* " prefix + name + side padding.
    let isCur = name == g.currentBranch
    let label = if isCur: "* " & name else: name
    let w = cint(label.len) * gW + cint(2 * 8)  # 8 = padding
    result.add(Rectangle(l: x, r: x + w, t: tabsR.t, b: tabsR.b))
    x += w

proc paintTabs(g: ptr GitPane, painter: ptr Painter, tabsR: Rectangle) =
  drawBlock(painter, tabsR, ui.theme.panel2)
  let rects = tabRects(g, tabsR)
  for i in 0 ..< g.branches.len:
    let r = rects[i]
    if r.r <= tabsR.l or r.l >= tabsR.r: continue
    let name = g.branches[i]
    let isCur = name == g.currentBranch
    let isView = name == g.selectedBranch
    let label = if isCur: "* " & name else: name
    let bg =
      if isView: ui.theme.selected
      else: ui.theme.panel2
    let fg =
      if isView: ui.theme.textSelected
      elif isCur: ui.theme.text
      else: ui.theme.textDisabled
    let clipped = Rectangle(l: max(r.l, tabsR.l), r: min(r.r, tabsR.r),
                            t: r.t, b: r.b)
    drawBlock(painter, clipped, bg)
    drawString(painter, clipped, label.cstring, label.len, fg,
               cint(ALIGN_CENTER), nil)
  drawBlock(painter,
            Rectangle(l: tabsR.l, r: tabsR.r, t: tabsR.b - 1, b: tabsR.b),
            ui.theme.border)

proc paintStatus(g: ptr GitPane, painter: ptr Painter, rect: Rectangle) =
  drawBlock(painter, rect, ui.theme.panel1)
  let (_, gH) = glyphDims()
  let header = "STATUS"
  drawString(painter,
             Rectangle(l: rect.l + 4, r: rect.r, t: rect.t, b: rect.t + gH),
             header.cstring, header.len, ui.theme.textDisabled,
             cint(ALIGN_LEFT), nil)
  let rowsTop = rect.t + gH
  let vr = visibleRowsIn(Rectangle(l: rect.l, r: rect.r,
                                    t: rowsTop, b: rect.b), gH)
  if not g.isGitRepo:
    drawString(painter,
               Rectangle(l: rect.l + 4, r: rect.r, t: rowsTop, b: rowsTop + gH),
               "(not a git repo)".cstring, 16, ui.theme.textDisabled,
               cint(ALIGN_LEFT), nil)
    return
  if g.status.len == 0:
    drawString(painter,
               Rectangle(l: rect.l + 4, r: rect.r, t: rowsTop, b: rowsTop + gH),
               "(clean)".cstring, 7, ui.theme.textDisabled,
               cint(ALIGN_LEFT), nil)
    return
  for i in 0 ..< vr:
    let idx = g.statusTopLine + i
    if idx >= g.status.len: break
    let y = rowsTop + cint(i) * gH
    let rr = Rectangle(l: rect.l, r: rect.r, t: y, b: y + gH)
    let isSel = idx == g.statusSelected
    let active = g.focused == gsStatus
    if isSel:
      let bg = if active: ui.theme.selected else: ui.theme.panel2
      drawBlock(painter, rr, bg)
    let st = g.status[idx]
    # Rewrite `??` (porcelain's untracked code) → `U ` since our embedded
    # bitmap font has no glyph for `?` and renders both bytes as fallback,
    # producing an unreadable double-glyph. `U` is the common shorthand.
    let codeOut = if st.code == "??": "U " else: st.code
    let txt = codeOut & " " & st.path
    let fg =
      if isSel and active: ui.theme.textSelected
      else: ui.theme.text
    drawString(painter,
               Rectangle(l: rect.l + 4, r: rect.r, t: y, b: y + gH),
               txt.cstring, txt.len, fg, cint(ALIGN_LEFT), nil)

proc paintLog(g: ptr GitPane, painter: ptr Painter, rect: Rectangle) =
  drawBlock(painter, rect, ui.theme.panel1)
  let (_, gH) = glyphDims()
  let header = "LOG (" & (if g.selectedBranch.len > 0: g.selectedBranch else: "HEAD") & ")"
  drawString(painter,
             Rectangle(l: rect.l + 4, r: rect.r, t: rect.t, b: rect.t + gH),
             header.cstring, header.len, ui.theme.textDisabled,
             cint(ALIGN_LEFT), nil)
  let rowsTop = rect.t + gH
  let vr = visibleRowsIn(Rectangle(l: rect.l, r: rect.r,
                                    t: rowsTop, b: rect.b), gH)
  if not g.isGitRepo: return
  let flat = flatLogRows(g)
  for i in 0 ..< vr:
    let idx = g.logTopLine + i
    if idx >= flat.len: break
    let row = flat[idx]
    let y = rowsTop + cint(i) * gH
    let rr = Rectangle(l: rect.l, r: rect.r, t: y, b: y + gH)
    let isSel = idx == g.logSelected
    let active = g.focused == gsLog
    if isSel:
      let bg = if active: ui.theme.selected else: ui.theme.panel2
      drawBlock(painter, rr, bg)
    let c = g.commits[row.commitIdx]
    if row.isCommit:
      let glyph = if c.expanded: "v " else: "> "
      let txt = glyph & c.hash & "  " & c.author & "  " & c.subject
      let fg =
        if isSel and active: ui.theme.textSelected
        else: ui.theme.text
      drawString(painter,
                 Rectangle(l: rect.l + 4, r: rect.r, t: y, b: y + gH),
                 txt.cstring, txt.len, fg, cint(ALIGN_LEFT), nil)
    else:
      let txt = "    " & c.files[row.fileIdx]
      let fg =
        if isSel and active: ui.theme.textSelected
        else: ui.theme.textDisabled
      drawString(painter,
                 Rectangle(l: rect.l + 4, r: rect.r, t: y, b: y + gH),
                 txt.cstring, txt.len, fg, cint(ALIGN_LEFT), nil)

# ---------- input --------------------------------------------------------

proc clampStatus(g: ptr GitPane) =
  if g.status.len == 0:
    g.statusSelected = 0; g.statusTopLine = 0; return
  if g.statusSelected < 0: g.statusSelected = 0
  if g.statusSelected >= g.status.len:
    g.statusSelected = g.status.len - 1
  let zones = zonesOf(g)
  let (_, gH) = glyphDims()
  let bodyH = max(cint(0), zones.statusR.b - zones.statusR.t - gH)
  let vr = max(1, int(bodyH) div max(1, int(gH)))
  if g.statusSelected < g.statusTopLine:
    g.statusTopLine = g.statusSelected
  elif g.statusSelected >= g.statusTopLine + vr:
    g.statusTopLine = g.statusSelected - vr + 1
  let maxTop = max(0, g.status.len - vr)
  if g.statusTopLine > maxTop: g.statusTopLine = maxTop
  if g.statusTopLine < 0: g.statusTopLine = 0

proc clampLog(g: ptr GitPane) =
  let n = flatLogRows(g).len
  if n == 0:
    g.logSelected = 0; g.logTopLine = 0; return
  if g.logSelected < 0: g.logSelected = 0
  if g.logSelected >= n: g.logSelected = n - 1
  let zones = zonesOf(g)
  let (_, gH) = glyphDims()
  let bodyH = max(cint(0), zones.logR.b - zones.logR.t - gH)
  let vr = max(1, int(bodyH) div max(1, int(gH)))
  if g.logSelected < g.logTopLine:
    g.logTopLine = g.logSelected
  elif g.logSelected >= g.logTopLine + vr:
    g.logTopLine = g.logSelected - vr + 1
  let maxTop = max(0, n - vr)
  if g.logTopLine > maxTop: g.logTopLine = maxTop
  if g.logTopLine < 0: g.logTopLine = 0

proc onTabClick(g: ptr GitPane, lx: cint, tabsR: Rectangle) =
  let rects = tabRects(g, tabsR)
  for i in 0 ..< rects.len:
    let r = rects[i]
    if lx >= r.l and lx < r.r:
      g.selectedBranch = g.branches[i]
      loadLog(g)
      g.logSelected = 0; g.logTopLine = 0
      elementRepaint(addr g.e, nil)
      return

proc onLogActivate(g: ptr GitPane) =
  let flat = flatLogRows(g)
  if g.logSelected < 0 or g.logSelected >= flat.len: return
  let row = flat[g.logSelected]
  if row.isCommit:
    let ci = row.commitIdx
    let h = g.commits[ci].hash
    # Debounce: X11 key auto-repeat can queue a second Enter while the
    # git show subprocess blocks; the queued event would re-toggle the row
    # back. Drop activates within 200ms on the same commit.
    let now = epochTime()
    if h == g.lastToggleHash and (now - g.lastToggleMs) < 0.2:
      return
    g.lastToggleMs = now
    g.lastToggleHash = h
    if not g.commits[ci].expanded:
      loadCommitFiles(g, ci)
    g.commits[ci].expanded = not g.commits[ci].expanded
    elementRepaint(addr g.e, nil)
  else:
    openCommitFileDiff(g, row.commitIdx, row.fileIdx)

proc onStatusActivate(g: ptr GitPane) =
  openWorkingDiff(g, g.statusSelected)

proc gitPaneMessage(element: ptr Element, message: Message,
                    di: cint, dp: pointer): cint {.cdecl.} =
  let g = cast[ptr GitPane](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let zones = zonesOf(g)
    paintTabs(g, painter, zones.tabsR)
    paintStatus(g, painter, zones.statusR)
    drawBlock(painter, zones.dividerR, ui.theme.border)
    paintLog(g, painter, zones.logR)
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, element.bounds, currentPalette.accent,
                 Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgUpdate:
    elementRepaint(element, nil)
    return 0

  elif message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w == nil: return 1
    let zones = zonesOf(g)
    let cx = w.cursorX
    let cy = w.cursorY
    if cy >= zones.tabsR.t and cy < zones.tabsR.b:
      onTabClick(g, cx, zones.tabsR)
      return 1
    let (_, gH) = glyphDims()
    if cy >= zones.statusR.t + gH and cy < zones.statusR.b:
      g.focused = gsStatus
      let row = g.statusTopLine + int(cy - (zones.statusR.t + gH)) div max(1, int(gH))
      if row >= 0 and row < g.status.len:
        g.statusSelected = row
      elementRepaint(element, nil)
      return 1
    if cy >= zones.logR.t + gH and cy < zones.logR.b:
      g.focused = gsLog
      let flat = flatLogRows(g)
      let row = g.logTopLine + int(cy - (zones.logR.t + gH)) div max(1, int(gH))
      if row >= 0 and row < flat.len:
        g.logSelected = row
        # Click on a commit row toggles expand directly (matches the
        # Enter/Space action so a single click previews the file list).
        let lr = flat[row]
        if lr.isCommit:
          let ci = lr.commitIdx
          let h = g.commits[ci].hash
          let now = epochTime()
          if not (h == g.lastToggleHash and (now - g.lastToggleMs) < 0.2):
            g.lastToggleMs = now
            g.lastToggleHash = h
            if not g.commits[ci].expanded:
              loadCommitFiles(g, ci)
            g.commits[ci].expanded = not g.commits[ci].expanded
        else:
          openCommitFileDiff(g, lr.commitIdx, lr.fileIdx)
      elementRepaint(element, nil)
      return 1
    return 1

  elif message == msgMouseWheel:
    if g.focused == gsStatus:
      g.statusTopLine += int(di) div 60
      clampStatus(g)
    else:
      g.logTopLine += int(di) div 60
      clampLog(g)
    elementRepaint(element, nil)
    return 1

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let win = element.window
    let alt = (win != nil and win.alt)
    let shift = (win != nil and win.shift)
    let code = k.code
    if alt: return 0   # let window-level pane nav handle Alt+*
    if code == int(KEYCODE_TAB):
      g.focused = if g.focused == gsStatus: gsLog else: gsStatus
      elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      if g.focused == gsStatus: inc g.statusSelected; clampStatus(g)
      else: inc g.logSelected; clampLog(g)
      elementRepaint(element, nil); return 1
    if code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      if g.focused == gsStatus: dec g.statusSelected; clampStatus(g)
      else: dec g.logSelected; clampLog(g)
      elementRepaint(element, nil); return 1
    if code == int(KEYCODE_ENTER):
      if g.focused == gsStatus: onStatusActivate(g)
      else: onLogActivate(g)
      return 1
    if code == int(KEYCODE_LEFT) or code == int(KEYCODE_LETTER('H')):
      # Cycle branch tab leftward.
      if g.branches.len > 0:
        let cur = g.branches.find(g.selectedBranch)
        let nxt = if cur <= 0: g.branches.len - 1 else: cur - 1
        g.selectedBranch = g.branches[nxt]
        loadLog(g); g.logSelected = 0; g.logTopLine = 0
        elementRepaint(element, nil)
      return 1
    if code == int(KEYCODE_RIGHT) or code == int(KEYCODE_LETTER('L')):
      if g.branches.len > 0:
        let cur = g.branches.find(g.selectedBranch)
        let nxt = if cur < 0 or cur + 1 >= g.branches.len: 0 else: cur + 1
        g.selectedBranch = g.branches[nxt]
        loadLog(g); g.logSelected = 0; g.logTopLine = 0
        elementRepaint(element, nil)
      return 1
    if shift: return 0
    return 0

  return 0

# ---------- create + install ---------------------------------------------

proc gitPaneCreate*(parent: ptr Element): ptr GitPane =
  let e = elementCreate(csize_t(sizeof(GitPane)), parent,
                        ELEMENT_V_FILL or ELEMENT_H_FILL or ELEMENT_TAB_STOP,
                        gitPaneMessage, "GitPane")
  let g = cast[ptr GitPane](e)
  g.focused = gsStatus
  theGitPane = g
  return g

proc cmdGst(args: seq[string]) =
  gitPaneRefresh()
  if theGitPane != nil:
    elementFocus(addr theGitPane.e)

proc cmdGlog(args: seq[string]) =
  let g = theGitPane
  if g == nil: return
  if args.len >= 1 and args[0].len > 0:
    g.selectedBranch = args[0]
  loadLog(g)
  g.logSelected = 0; g.logTopLine = 0
  elementRepaint(addr g.e, nil)
  elementFocus(addr g.e)

proc cmdGbr(args: seq[string]) =
  ## Simple branches dump — feedback path is a Δ tab so the full list (with
  ## any verbose flags the user passed) lands in the editor.
  var gargs = @["branch", "-v"]
  for a in args: gargs.add(a)
  let (_, body) = runGit(gargs)
  if editor.theEditor != nil:
    editorOpenSynthetic(editor.theEditor, "diff://BRANCHES/list", body)

proc cmdGco(args: seq[string]) =
  if args.len < 1: return
  let name = args[0]
  let (ok, msg) = runGit(["checkout", name])
  if not ok and editor.theEditor != nil:
    editorOpenSynthetic(editor.theEditor, "diff://CHECKOUT/error",
                        "git checkout " & name & " failed:\n\n" & msg)
  gitPaneRefresh()

proc splitMultiDiff(raw: string): tuple[header: string, files: seq[tuple[path, body: string]]] =
  ## Splits a multi-file `git show` / `git diff` body into:
  ##   header — anything before the first `diff --git` (commit metadata)
  ##   files  — one (path, body) per `diff --git a/<path> b/<path>` block
  ## Each file body covers from its `diff --git` line through the line
  ## just before the next `diff --git` (or EOF).
  result.files = @[]
  let lines = raw.splitLines()
  var i = 0
  var headerBuf = ""
  while i < lines.len and not lines[i].startsWith("diff --git "):
    headerBuf.add(lines[i]); headerBuf.add('\n')
    inc i
  if headerBuf.len > 0 and headerBuf[^1] == '\n':
    headerBuf.setLen(headerBuf.len - 1)
  result.header = headerBuf
  while i < lines.len:
    let head = lines[i]
    var path = ""
    # `diff --git a/<p> b/<p>` — pick the b-side path, robust to spaces.
    let bAt = head.find(" b/", start = len("diff --git "))
    if bAt > 0:
      path = head[bAt + 3 .. ^1]
    var bodyBuf = head & "\n"
    inc i
    while i < lines.len and not lines[i].startsWith("diff --git "):
      bodyBuf.add(lines[i]); bodyBuf.add('\n')
      inc i
    if bodyBuf.len > 0 and bodyBuf[^1] == '\n':
      bodyBuf.setLen(bodyBuf.len - 1)
    if path.len == 0:
      path = "diff_" & $(result.files.len + 1)
    result.files.add((path: path, body: bodyBuf))

proc cmdGshow(args: seq[string]) =
  if args.len < 1 or editor.theEditor == nil: return
  let h = args[0]
  let (_, body) = runGit(["show", h])
  let split = splitMultiDiff(body)
  if split.header.len > 0:
    editorOpenSynthetic(editor.theEditor,
                        "diff://" & h & "/__commit",
                        split.header)
  for f in split.files:
    editorOpenSynthetic(editor.theEditor,
                        "diff://" & h & "/" & f.path,
                        formatDiffOutput(f.body))
  if split.files.len == 0 and split.header.len == 0:
    editorOpenSynthetic(editor.theEditor,
                        "diff://" & h & "/__commit",
                        "(empty diff for " & h & ")")

proc cmdGdiff(args: seq[string]) =
  if editor.theEditor == nil: return
  var gargs = @["diff"]
  if args.len >= 1: gargs.add(args[0])
  let (_, body) = runGit(gargs)
  if body.len == 0:
    let synth =
      if args.len >= 1: "diff://WORKING/" & args[0]
      else: "diff://WORKING/__all"
    editorOpenSynthetic(editor.theEditor, synth, "(no changes)")
    return
  let split = splitMultiDiff(body)
  for f in split.files:
    editorOpenSynthetic(editor.theEditor,
                        "diff://WORKING/" & f.path,
                        formatDiffOutput(f.body))
  if split.files.len == 0:
    let synth =
      if args.len >= 1: "diff://WORKING/" & args[0]
      else: "diff://WORKING/__all"
    editorOpenSynthetic(editor.theEditor, synth, formatDiffOutput(body))

proc gitPaneInstall*() =
  project.registerProjectChange(proc() = onProjectChange())
  registerCommand("gst", cmdGst)
  registerCommand("glog", cmdGlog)
  registerCommand("gbr", cmdGbr)
  registerCommand("gco", cmdGco)
  registerCommand("gshow", cmdGshow)
  registerCommand("gdiff", cmdGdiff)
  # Initial seed + cache snapshot so the first poll tick doesn't see a
  # spurious change.
  gitPaneRefresh()
  if theGitPane != nil:
    snapshotCaches(theGitPane, dotGitDir())
