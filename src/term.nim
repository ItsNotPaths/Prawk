import std/[os, strutils]
import posix
import luigi
import pty, project, font, config, clipboard, theme

{.passC: "-I\"" & (currentSourcePath.parentDir.parentDir / "vendor" / "libvterm" / "include") & "\"".}
{.compile: "../vendor/libvterm/src/encoding.c".}
{.compile: "../vendor/libvterm/src/keyboard.c".}
{.compile: "../vendor/libvterm/src/mouse.c".}
{.compile: "../vendor/libvterm/src/parser.c".}
{.compile: "../vendor/libvterm/src/pen.c".}
{.compile: "../vendor/libvterm/src/screen.c".}
{.compile: "../vendor/libvterm/src/state.c".}
{.compile: "../vendor/libvterm/src/unicode.c".}
{.compile: "../vendor/libvterm/src/vterm.c".}

{.emit: """/*INCLUDESECTION*/
#include "vterm.h"
#include <string.h>
""".}

type
  VTerm* {.importc, incompleteStruct, header: "vterm.h".} = object
  VTermScreen* {.importc, incompleteStruct, header: "vterm.h".} = object
  VTermState* {.importc, incompleteStruct, header: "vterm.h".} = object
  VTermPos {.importc: "VTermPos", header: "vterm.h", bycopy.} = object
    row, col: cint

  VTermScreenCallbacks {.importc: "VTermScreenCallbacks", header: "vterm.h", bycopy.} = object
    damage, moverect, movecursor, settermprop, bell, resize: pointer
    sb_pushline, sb_popline, sb_clear, sb_pushline4: pointer

const
  VTERM_PROP_CURSORVISIBLE = cint(1)

proc vterm_new(rows, cols: cint): ptr VTerm {.importc, header: "vterm.h".}
proc vterm_free(vt: ptr VTerm) {.importc, header: "vterm.h".}
proc vterm_set_size(vt: ptr VTerm, rows, cols: cint) {.importc, header: "vterm.h".}
proc vterm_set_utf8(vt: ptr VTerm, isUtf8: cint) {.importc, header: "vterm.h".}
proc vterm_input_write(vt: ptr VTerm, bytes: cstring, len: csize_t): csize_t
  {.importc, header: "vterm.h", discardable.}
proc vterm_obtain_screen(vt: ptr VTerm): ptr VTermScreen {.importc, header: "vterm.h".}
proc vterm_obtain_state(vt: ptr VTerm): ptr VTermState {.importc, header: "vterm.h".}
proc vterm_state_get_cursorpos(state: ptr VTermState, pos: ptr VTermPos)
  {.importc, header: "vterm.h".}
proc vterm_screen_set_callbacks(screen: ptr VTermScreen,
                                cbs: ptr VTermScreenCallbacks, user: pointer)
  {.importc, header: "vterm.h".}
proc vterm_screen_reset(screen: ptr VTermScreen, hard: cint) {.importc, header: "vterm.h".}
proc vterm_screen_enable_altscreen(screen: ptr VTermScreen, alt: cint)
  {.importc, header: "vterm.h".}

# Flat per-cell snapshot we hand back from C. Avoids dragging libvterm's bitfield
# attrs and tagged-union VTermColor into Nim's FFI surface — every call into the
# library to read a cell goes through prawkReadCellAt / prawkReadSbCell, which
# do the bitfield and color-classification work on the C side.
#
# fg_basic / bg_basic: 1..8 when the source colour was indexed 0..7 (basic ANSI),
# else 0. We keep that path so the prawk theme palette can map the eight named
# ANSI colours instead of using libvterm's hard-coded RGB defaults; non-basic
# (16..255 indexed, full RGB, default-fg, default-bg) flows through the RGB
# fields or the *_default flag.
type
  PrawkCell {.bycopy.} = object
    ch: uint32
    reverse: uint8
    fg_default, bg_default: uint8
    fg_basic, bg_basic: uint8
    fg_r, fg_g, fg_b: uint8
    bg_r, bg_g, bg_b: uint8

proc prawkReadCellAt(screen: ptr VTermScreen, row, col: cint, output: ptr PrawkCell) =
  {.emit: """
  VTermPos p_; p_.row = `row`; p_.col = `col`;
  VTermScreenCell c_;
  memset(`output`, 0, sizeof(*`output`));
  if (!vterm_screen_get_cell(`screen`, p_, &c_)) return;
  `output`->ch = c_.chars[0];
  `output`->reverse = c_.attrs.reverse;
  if (c_.fg.type & 0x02) { `output`->fg_default = 1; }
  else if ((c_.fg.type & 0x01) == 0x01 && c_.fg.indexed.idx < 8) {
    `output`->fg_basic = c_.fg.indexed.idx + 1;
  } else {
    VTermColor fgc = c_.fg;
    vterm_screen_convert_color_to_rgb(`screen`, &fgc);
    `output`->fg_r = fgc.rgb.red; `output`->fg_g = fgc.rgb.green; `output`->fg_b = fgc.rgb.blue;
  }
  if (c_.bg.type & 0x04) { `output`->bg_default = 1; }
  else if ((c_.bg.type & 0x01) == 0x01 && c_.bg.indexed.idx < 8) {
    `output`->bg_basic = c_.bg.indexed.idx + 1;
  } else {
    VTermColor bgc = c_.bg;
    vterm_screen_convert_color_to_rgb(`screen`, &bgc);
    `output`->bg_r = bgc.rgb.red; `output`->bg_g = bgc.rgb.green; `output`->bg_b = bgc.rgb.blue;
  }
""".}

proc prawkReadSbCell(screen: ptr VTermScreen, cells: pointer, idx: cint,
                     output: ptr PrawkCell) =
  ## Same as prawkReadCellAt but reads from the const VTermScreenCell* row that
  ## sb_pushline hands us, rather than re-querying the screen.
  {.emit: """
  const VTermScreenCell *c_ = ((const VTermScreenCell *)`cells`) + `idx`;
  memset(`output`, 0, sizeof(*`output`));
  `output`->ch = c_->chars[0];
  `output`->reverse = c_->attrs.reverse;
  if (c_->fg.type & 0x02) { `output`->fg_default = 1; }
  else if ((c_->fg.type & 0x01) == 0x01 && c_->fg.indexed.idx < 8) {
    `output`->fg_basic = c_->fg.indexed.idx + 1;
  } else {
    VTermColor fgc = c_->fg;
    vterm_screen_convert_color_to_rgb(`screen`, &fgc);
    `output`->fg_r = fgc.rgb.red; `output`->fg_g = fgc.rgb.green; `output`->fg_b = fgc.rgb.blue;
  }
  if (c_->bg.type & 0x04) { `output`->bg_default = 1; }
  else if ((c_->bg.type & 0x01) == 0x01 && c_->bg.indexed.idx < 8) {
    `output`->bg_basic = c_->bg.indexed.idx + 1;
  } else {
    VTermColor bgc = c_->bg;
    vterm_screen_convert_color_to_rgb(`screen`, &bgc);
    `output`->bg_r = bgc.rgb.red; `output`->bg_g = bgc.rgb.green; `output`->bg_b = bgc.rgb.blue;
  }
""".}

type
  ScrollLine = seq[PrawkCell]

  Terminal* = object
    e*: Element
    name*: string
    locked*: bool
    cwd*: string
    rows, cols: int
    vt: ptr VTerm
    screen: ptr VTermScreen
    state: ptr VTermState
    cbs: VTermScreenCallbacks
    ptyFd*: cint
    pid*: Pid
    readBuf: array[4096, char]
    selAnchorR, selAnchorC: int
    selEndR, selEndC: int
    hasSel: bool
    cursorVisible*: bool
    history: seq[ScrollLine]
    scrollOffset: int  # 0 = live; N = N lines scrolled back into history

const
  scrollbackMax = 2000
  scrollbackOver = 256  # trim only when this many over the cap, amortizing the slice

var allTerminals*: seq[ptr Terminal]

proc cbSettermProp(prop: cint, val: pointer, user: pointer): cint {.cdecl.} =
  let t = cast[ptr Terminal](user)
  if t == nil: return 0
  if prop == VTERM_PROP_CURSORVISIBLE:
    var b: cint = 0
    {.emit: "`b` = ((VTermValue *)`val`)->boolean;".}
    t.cursorVisible = (b != 0)
  return 1

proc cbSbPushline(cols: cint, cells: pointer, user: pointer): cint {.cdecl.} =
  ## libvterm fires this once per line that scrolls off the top of the main
  ## screen.
  let t = cast[ptr Terminal](user)
  if t == nil or t.screen == nil: return 0
  let n = int(cols)
  var row = newSeq[PrawkCell](n)
  var blank = true
  for i in 0 ..< n:
    prawkReadSbCell(t.screen, cells, cint(i), addr row[i])
    let ch = row[i].ch
    if ch != 0 and ch != uint32(' '):
      blank = false
  # Skip blank rows — they're visual noise in the pageup view.
  if not blank:
    t.history.add(row)
    if t.history.len > scrollbackMax + scrollbackOver:
      let dropN = t.history.len - scrollbackMax
      t.history = t.history[dropN .. ^1]
    if t.scrollOffset > 0:
      t.scrollOffset = min(t.history.len, t.scrollOffset + 1)
  return 1

proc colorOfBasic(idx: uint8, fg: bool): uint32 =
  ## Map ANSI 0..7 (passed in here as 1..8 to keep the slot 0 → "no basic color"
  ## flag) onto the prawk theme palette so user themes drive terminal output.
  let p = currentPalette
  case int(idx)
  of 1: p.borderDark    # BLACK
  of 2: p.urgent        # RED
  of 3: p.codeType      # GREEN
  of 4: p.codeString    # YELLOW
  of 5: p.accent        # BLUE
  of 6: p.codeKeyword   # MAGENTA
  of 7: p.codeReturnType # CYAN
  of 8: p.fg            # WHITE
  else: (if fg: p.fg else: p.bg)

proc cellFg(c: PrawkCell): uint32 =
  if c.fg_default != 0: currentPalette.fg
  elif c.fg_basic != 0: colorOfBasic(c.fg_basic, true)
  else: (uint32(c.fg_r) shl 16) or (uint32(c.fg_g) shl 8) or uint32(c.fg_b)

proc cellBg(c: PrawkCell): uint32 =
  if c.bg_default != 0: currentPalette.bg
  elif c.bg_basic != 0: colorOfBasic(c.bg_basic, false)
  else: (uint32(c.bg_r) shl 16) or (uint32(c.bg_g) shl 8) or uint32(c.bg_b)

proc selOrdered(t: ptr Terminal): tuple[sR, sC, eR, eC: int] =
  let aR = t.selAnchorR; let aC = t.selAnchorC
  let bR = t.selEndR;    let bC = t.selEndC
  if (aR < bR) or (aR == bR and aC <= bC): (aR, aC, bR, bC)
  else: (bR, bC, aR, aC)

proc inSel(t: ptr Terminal, r, c: int): bool =
  if not t.hasSel: return false
  let (sR, sC, eR, eC) = selOrdered(t)
  if r < sR or r > eR: return false
  if r == sR and r == eR: return c >= sC and c < eC
  if r == sR: return c >= sC
  if r == eR: return c < eC
  true   # fully-selected interior row

proc selCopyText(t: ptr Terminal): string =
  if t.vt == nil or not t.hasSel: return ""
  let (sR, sC, eR, eC) = selOrdered(t)
  var rows: seq[string] = @[]
  var cell: PrawkCell
  for r in max(0, sR) .. min(t.rows - 1, eR):
    let lo = if r == sR: max(0, sC) else: 0
    let hi = if r == eR: min(t.cols, eC) else: t.cols
    var row = ""
    for c in lo ..< hi:
      prawkReadCellAt(t.screen, cint(r), cint(c), addr cell)
      var ch = int(cell.ch)
      if ch < 32 or ch > 126: ch = 32
      row.add(char(ch))
    # Trim trailing spaces per row — terminals pad with spaces to ncol.
    var k = row.len
    while k > 0 and row[k - 1] == ' ': dec k
    row.setLen(k)
    rows.add(row)
  rows.join("\n")

proc cellAt(t: ptr Terminal, px, py: cint): tuple[r, c: int] =
  let (gW, gH) = glyphDims()
  let lx = max(cint(0), px - t.e.bounds.l)
  let ly = max(cint(0), py - t.e.bounds.t)
  let r = min(t.rows - 1, max(0, int(ly div max(cint(1), gH))))
  let c = min(t.cols - 1, max(0, int(lx div max(cint(1), gW))))
  (r, c)

proc terminalMessage(element: ptr Element, message: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let t = cast[ptr Terminal](element)
  if message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let (r, c) = cellAt(t, w.cursorX, w.cursorY)
      t.selAnchorR = r; t.selAnchorC = c
      t.selEndR = r;    t.selEndC = c
      t.hasSel = false
      elementRepaint(element, nil)
    return 1

  if message == msgMouseDrag:
    let w = element.window
    if w != nil:
      let (r, c) = cellAt(t, w.cursorX, w.cursorY)
      t.selEndR = r; t.selEndC = c
      t.hasSel = (t.selAnchorR != r or t.selAnchorC != c)
      if t.hasSel:
        clipboardSetPrimary(selCopyText(t))
      elementRepaint(element, nil)
    return 1

  if message == msgUpdate:
    elementRepaint(element, nil)
    return 0

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    if t.vt == nil: return 0
    let (gW, gH) = glyphDims()
    let bx = t.e.bounds.l
    let by = t.e.bounds.t
    var buf: array[2, char]
    buf[1] = '\0'
    let drawCursor = t.cursorVisible and
                     element.window != nil and
                     element.window.focused == element
    var curPos: VTermPos
    vterm_state_get_cursorpos(t.state, addr curPos)
    let nrow = t.rows
    let ncol = t.cols
    let histLines = min(t.scrollOffset, t.history.len)
    var liveCell: PrawkCell
    for r in 0 ..< nrow:
      let isHist = r < histLines
      let liveR = r - histLines
      var hLine: ScrollLine
      if isHist:
        hLine = t.history[t.history.len - histLines + r]
      for col in 0 ..< ncol:
        let x = bx + cint(col) * gW
        let y = by + cint(r) * gH
        var fg, bg: uint32
        var ch: uint32
        var reverse = false
        if isHist:
          if col < hLine.len:
            let c2 = hLine[col]
            ch = c2.ch
            fg = cellFg(c2); bg = cellBg(c2)
            reverse = c2.reverse != 0
          else:
            ch = uint32(' ')
            fg = currentPalette.fg; bg = currentPalette.bg
        else:
          prawkReadCellAt(t.screen, cint(liveR), cint(col), addr liveCell)
          ch = liveCell.ch
          fg = cellFg(liveCell); bg = cellBg(liveCell)
          reverse = liveCell.reverse != 0
        if reverse: swap(fg, bg)
        if not isHist and drawCursor and int(curPos.row) == liveR and int(curPos.col) == col:
          swap(fg, bg)
        if not isHist and inSel(t, liveR, col):
          bg = ui.theme.selected
        drawBlock(painter, Rectangle(l: x, r: x + gW, t: y, b: y + gH), bg)
        let cp = int(ch)
        # libvterm marks the trailing half of a double-width glyph by writing
        # 0xFFFFFFFF (== (uint32_t)-1) into chars[0]; the leading cell already
        # painted the glyph, so treat the gap as blank. Anything above the
        # Unicode max is also bogus and must be skipped — letting it reach
        # `cint(cp)` is a RangeDefect (and silent UB under -d:danger).
        if cp <= 32 or cp == 0x7F or cp > 0x10FFFF:
          discard  # blank cell / wide-char gap
        elif cp <= 126:
          buf[0] = char(cp)
          drawString(painter,
            Rectangle(l: x, r: x + gW, t: y, b: y + gH),
            cast[cstring](addr buf[0]), 1,
            fg, cint(ALIGN_LEFT), nil)
        else:
          drawGlyphCp(painter, x, y, cint(cp), fg)
    if element.window != nil and element.window.focused == element:
      let b = t.e.bounds
      drawBorder(painter, b, currentPalette.accent, Rectangle(l: 2, r: 2, t: 2, b: 2))
    return 1

  elif message == msgMouseWheel:
    # di > 0 = wheel down (toward live); di < 0 = wheel up (back in history).
    # Step is roughly one line per notch on a typical mouse.
    let step = -(int(di) div 40)
    let newOff = clamp(t.scrollOffset + step, 0, t.history.len)
    if newOff != t.scrollOffset:
      t.scrollOffset = newOff
      elementRepaint(element, nil)
      return 1
    # At the limit — let the parent stack scroll between terminals.
    return 0

  elif message == msgLayout:
    let w = t.e.bounds.r - t.e.bounds.l
    let h = t.e.bounds.b - t.e.bounds.t
    let (gW, gH) = glyphDims()
    let newCols = max(4, int(w) div max(1, int(gW)))
    let newRows = max(1, int(h) div max(1, int(gH)))
    if newCols != t.cols or newRows != t.rows:
      t.cols = newCols
      t.rows = newRows
      if t.vt != nil:
        vterm_set_size(t.vt, cint(t.rows), cint(t.cols))
      if t.ptyFd >= 0:
        pty.resize(t.ptyFd, t.rows, t.cols)
    return 0

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    if t.ptyFd < 0: return 0
    let w = element.window
    if w != nil and w.alt: return 0
    let ctrl  = (w != nil and w.ctrl)
    let shift = (w != nil and w.shift)
    let code = k.code

    # --- Ctrl+Shift+Up/Down scroll the scrollback buffer -----------------
    if ctrl and shift and (code == int(KEYCODE_UP) or code == int(KEYCODE_DOWN)):
      let pageStep = max(1, t.rows div 2)
      let delta = if code == int(KEYCODE_UP): pageStep else: -pageStep
      let newOff = clamp(t.scrollOffset + delta, 0, t.history.len)
      if newOff != t.scrollOffset:
        t.scrollOffset = newOff
        elementRepaint(element, nil)
      return 1

    # --- Shift+arrow extends selection over the visible grid -------------
    # Done before PTY pass-through so vim/tmux inside the terminal don't see
    # these. Tradeoff is documented; a config knob can ungate later.
    let isArrow = code == int(KEYCODE_LEFT) or code == int(KEYCODE_RIGHT) or
                  code == int(KEYCODE_UP) or code == int(KEYCODE_DOWN) or
                  code == int(KEYCODE_HOME) or code == int(KEYCODE_END)
    if shift and not ctrl and isArrow:
      if not t.hasSel:
        # Anchor at the current cursor position (where the user last looked).
        if t.vt != nil:
          var cur: VTermPos
          vterm_state_get_cursorpos(t.state, addr cur)
          t.selAnchorR = int(cur.row); t.selAnchorC = int(cur.col)
          t.selEndR = t.selAnchorR; t.selEndC = t.selAnchorC
        t.hasSel = true
      var nr = t.selEndR
      var nc = t.selEndC
      if code == int(KEYCODE_LEFT):
        if nc > 0: dec nc
        elif nr > 0: dec nr; nc = t.cols - 1
      elif code == int(KEYCODE_RIGHT):
        if nc < t.cols - 1: inc nc
        elif nr < t.rows - 1: inc nr; nc = 0
      elif code == int(KEYCODE_UP):
        if nr > 0: dec nr
      elif code == int(KEYCODE_DOWN):
        if nr < t.rows - 1: inc nr
      elif code == int(KEYCODE_HOME):
        nc = 0
      elif code == int(KEYCODE_END):
        nc = t.cols - 1
      t.selEndR = nr; t.selEndC = nc
      if t.selEndR == t.selAnchorR and t.selEndC == t.selAnchorC:
        t.hasSel = false
      if t.hasSel:
        clipboardSetPrimary(selCopyText(t))
      elementRepaint(element, nil)
      return 1

    # --- IDE / legacy copy-paste remap ----------------------------------
    if ctrl and code == int(KEYCODE_LETTER('C')):
      # INTR byte; the slave's line discipline (ISIG) turns it into SIGINT
      # delivered to the foreground process group, so TUIs running inside
      # the shell (claude, vim) actually see the interrupt. Killing t.pid
      # would only signal the shell, which usually swallows it.
      let intr = "\x03"
      case config.terminalCopyPaste
      of tcpIde:
        if shift:
          # Force-interrupt escape hatch even when a selection is held.
          discard write(t.ptyFd, intr.cstring, 1)
        elif t.hasSel:
          clipboardSetBoth(selCopyText(t))
        else:
          discard write(t.ptyFd, intr.cstring, 1)
        return 1
      of tcpLegacy:
        if shift:
          if t.hasSel: clipboardSetBoth(selCopyText(t))
          return 1
        # Plain Ctrl+C falls through to PTY pass-through below (SIGINT).
    if ctrl and code == int(KEYCODE_LETTER('V')):
      case config.terminalCopyPaste
      of tcpIde:
        let txt = clipboardGet()
        if txt.len > 0:
          discard write(t.ptyFd, txt.cstring, txt.len)
        return 1
      of tcpLegacy:
        if shift:
          let txt = clipboardGet()
          if txt.len > 0:
            discard write(t.ptyFd, txt.cstring, txt.len)
          return 1
        # Plain Ctrl+V falls through (literal-quote in some apps).

    var seqStr: string = ""
    if code == int(KEYCODE_LEFT):        seqStr = "\x1b[D"
    elif code == int(KEYCODE_RIGHT):     seqStr = "\x1b[C"
    elif code == int(KEYCODE_UP):        seqStr = "\x1b[A"
    elif code == int(KEYCODE_DOWN):      seqStr = "\x1b[B"
    elif code == int(KEYCODE_HOME):      seqStr = "\x1b[H"
    elif code == int(KEYCODE_END):       seqStr = "\x1b[Y"
    elif code == int(KEYCODE_ENTER):     seqStr = "\r"
    elif code == int(KEYCODE_BACKSPACE): seqStr = "\x7f"
    elif code == int(KEYCODE_ESCAPE):    seqStr = "\x1b"
    elif code == int(KEYCODE_TAB):
      # Shift+Tab → CSI Z ("back tab"); TUIs (claude, vim, readline) key off this.
      seqStr = if shift: "\x1b[Z" else: "\t"
    # Only an actual byte-producing keypress should clear the selection;
    # standalone modifier holds (Ctrl by itself, Shift by itself) must not,
    # otherwise Ctrl+C never sees the selection.
    let producesBytes = seqStr.len > 0 or k.textBytes > 0
    if producesBytes and t.hasSel:
      t.hasSel = false
    if producesBytes and t.scrollOffset > 0:
      t.scrollOffset = 0
    if seqStr.len > 0:
      discard write(t.ptyFd, seqStr.cstring, seqStr.len)
    elif k.textBytes > 0:
      discard write(t.ptyFd, k.text, int(k.textBytes))
    if producesBytes: elementRepaint(element, nil)
    return 1

  elif message == msgDestroy:
    if t.vt != nil:
      vterm_free(t.vt); t.vt = nil; t.screen = nil; t.state = nil
    if t.ptyFd >= 0:
      discard close(t.ptyFd); t.ptyFd = -1
    if t.pid > 0:
      discard kill(t.pid, SIGTERM)
      var st: cint
      discard waitpid(t.pid, st, WNOHANG)
      t.pid = Pid(-1)
    for i, p in allTerminals:
      if p == t:
        allTerminals.del(i); break
    return 0

  return 0

proc terminalCreate*(parent: ptr Element, flags: uint32 = 0): ptr Terminal =
  let e = elementCreate(csize_t(sizeof(Terminal)), parent, flags or ELEMENT_TAB_STOP,
                        terminalMessage, "Terminal")
  let t = cast[ptr Terminal](e)
  t.rows = 24; t.cols = 80
  t.cursorVisible = true
  t.vt = vterm_new(cint(t.rows), cint(t.cols))
  vterm_set_utf8(t.vt, 1)
  t.screen = vterm_obtain_screen(t.vt)
  t.state = vterm_obtain_state(t.vt)
  vterm_screen_enable_altscreen(t.screen, 1)
  t.cbs.settermprop = cast[pointer](cbSettermProp)
  t.cbs.sb_pushline = cast[pointer](cbSbPushline)
  vterm_screen_set_callbacks(t.screen, addr t.cbs, t)
  vterm_screen_reset(t.screen, 1)
  let (fd, pid) = startShell(t.rows, t.cols, project.projectRoot,
                             config.terminalTerm)
  t.ptyFd = fd
  t.pid = pid
  allTerminals.add(t)
  return t

proc termWrite*(t: ptr Terminal, s: string) =
  if t == nil or t.vt == nil or s.len == 0: return
  discard vterm_input_write(t.vt, s.cstring, csize_t(s.len))
  elementRepaint(addr t.e, nil)

proc termRunCmd*(t: ptr Terminal, line: string) =
  ## Write a command line into the PTY, appending a newline.
  if t == nil or t.ptyFd < 0 or line.len == 0: return
  let payload = line & "\n"
  discard write(t.ptyFd, payload.cstring, payload.len)

proc termRefreshCwd*(t: ptr Terminal) =
  ## Cheap readlink on /proc/<pid>/cwd. Updates the cached cwd for the
  ## per-terminal title bar. No-op if the proc is gone.
  if t == nil or t.pid <= 0: return
  let p = "/proc/" & $cint(t.pid) & "/cwd"
  try:
    t.cwd = expandSymlink(p)
  except OSError, IOError:
    discard

proc drainAll*() =
  for t in allTerminals:
    if t.ptyFd < 0 or t.vt == nil: continue
    while true:
      let n = read(t.ptyFd, addr t.readBuf[0], t.readBuf.len)
      if n <= 0: break
      discard vterm_input_write(t.vt, cast[cstring](addr t.readBuf[0]), csize_t(n))
      elementRepaint(addr t.e, nil)
      if n < t.readBuf.len: break
