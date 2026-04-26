## Compile-time-gated terminal debug instrumentation.
##
## Build with `nim ... -d:termDebug`. Without that define every entry point
## here is a no-op and the file contributes ~0 bytes after gc-sections.
##
## When enabled, each terminal in `allTerminals` writes three files in
## /tmp keyed by 1-based stack index N:
##   /tmp/prawk-term-N.raw   raw PTY bytes (replayable: `cat ... | alacritty`)
##   /tmp/prawk-term-N.esc   pretty-printed control sequences, one per line,
##                           prefixed with `+` (libtmt acts), `~` (libtmt
##                           silently absorbs / no effect), or `x` (libtmt
##                           drops AND spills bytes onto the screen)
##   /tmp/prawk-term-N.grid  on-demand snapshot of libtmt's grid (codepoint
##                           per cell) + cursor + screen size
##
## Files are appended to. `dbgInit` truncates them once at startup so a fresh
## prawk run starts with empty logs.

when defined(termDebug):
  import std/[strutils, unicode]

  type EscState = enum esText, esEsc, esCsi, esOsc, esOscEsc, esSs3
  type ParserState* = object
    state: EscState
    buf: string

  proc escapeByte(b: byte): string =
    case b
    of 0x1B: "\\e"
    of 0x07: "\\a"
    of 0x08: "\\b"
    of 0x09: "\\t"
    of 0x0A: "\\n"
    of 0x0D: "\\r"
    of 0x20 .. 0x7E: $char(b)
    else: "\\x" & toHex(b.int, 2)

  proc termIndex(idx: int): string = $(idx + 1)

  proc rawPath(idx: int): string  = "/tmp/prawk-term-" & termIndex(idx) & ".raw"
  proc escPath(idx: int): string  = "/tmp/prawk-term-" & termIndex(idx) & ".esc"
  proc gridPath(idx: int): string = "/tmp/prawk-term-" & termIndex(idx) & ".grid"

  proc appendBin(path: string, data: pointer, n: int) =
    let f = open(path, fmAppend)
    try: discard f.writeBuffer(data, n)
    finally: f.close()

  proc appendLine(path, line: string) =
    let f = open(path, fmAppend)
    try: f.writeLine(line)
    finally: f.close()

  proc truncFile(path: string) =
    let f = open(path, fmWrite)
    f.close()

  # CSI terminators libtmt's handlechar acts on. h/l are conditional below.
  const csiActed = {'A','B','C','D','E','F','G','d','H','f','I','J','K',
                    'L','M','P','S','T','X','Z','b','c','g','m','n','s',
                    'u','@'}

  proc classifyCsi(params: string, terminator: char): char =
    ## Returns '+', '~', or 'x'.
    if terminator == 'i':
      return '~'  # explicitly absorbed, no effect
    if terminator == 'h' or terminator == 'l':
      # libtmt only acts when the *single* param == 25.
      var p = params
      if p.len > 0 and p[0] == '?':
        p = p[1 .. ^1]
      if p == "25": return '+'
      return '~'
    if terminator in csiActed:
      return '+'
    'x'

  proc classifyEsc(byte: char): char =
    case byte
    of 'H', '7', '8', 'c': '+'
    of '+', '*', '(', ')': '~'
    else: 'x'

  proc emitEsc(idx: int, marker: char, label, payload: string) =
    appendLine(escPath(idx), marker & " " & label & "  " & payload)

  proc feedByte(idx: int, ps: var ParserState, b: byte) =
    case ps.state
    of esText:
      if b == 0x1B:
        ps.state = esEsc
        ps.buf.setLen(0)
        ps.buf.add("\\e")
      elif b == 0x07:
        emitEsc(idx, '+', "BEL", "\\a")
      elif b == 0x0D or b == 0x0A or b == 0x08 or b == 0x09:
        # Don't spam the .esc log with every CR/LF; track in .raw only.
        discard
    of esEsc:
      ps.buf.add(escapeByte(b))
      let c = char(b)
      if c == '[':
        ps.state = esCsi
      elif c == ']':
        ps.state = esOsc
      elif c == 'O':
        ps.state = esSs3
      elif c == 'P' or c == 'X' or c == '^' or c == '_':
        # DCS / SOS / PM / APC — libtmt drops, may spill.
        ps.state = esOsc  # treat as string-terminator-bounded
      else:
        emitEsc(idx, classifyEsc(c), "ESC " & c, ps.buf)
        ps.state = esText
        ps.buf.setLen(0)
    of esCsi:
      ps.buf.add(escapeByte(b))
      let c = char(b)
      if (b >= 0x40 and b <= 0x7E):
        # Final byte. Pull params out of the buffer between '[' and final.
        let lb = ps.buf.find("[")
        var params = ""
        if lb >= 0 and lb + 1 < ps.buf.len - 1:
          params = ps.buf[lb + 1 ..< ps.buf.len - 1]
        let marker = classifyCsi(params, c)
        emitEsc(idx, marker, "CSI " & params & " " & c, ps.buf)
        ps.state = esText
        ps.buf.setLen(0)
    of esOsc:
      let c = char(b)
      if b == 0x07:
        # OSC terminated by BEL.
        ps.buf.add("\\a")
        emitEsc(idx, 'x', "OSC", ps.buf)
        ps.state = esText
        ps.buf.setLen(0)
      elif b == 0x1B:
        ps.state = esOscEsc
      else:
        ps.buf.add(escapeByte(b))
        if ps.buf.len > 200:
          emitEsc(idx, 'x', "OSC(unterminated)", ps.buf)
          ps.state = esText
          ps.buf.setLen(0)
    of esOscEsc:
      ps.buf.add("\\e")
      ps.buf.add(escapeByte(b))
      emitEsc(idx, 'x', "OSC", ps.buf)
      ps.state = esText
      ps.buf.setLen(0)
    of esSs3:
      ps.buf.add(escapeByte(b))
      emitEsc(idx, '~', "SS3 " & char(b), ps.buf)
      ps.state = esText
      ps.buf.setLen(0)

  # ---- public API ----------------------------------------------------------

  var initialised = false

  proc dbgInit*() =
    if initialised: return
    initialised = true
    # Wipe any prior session's logs for slots 1..16 — generous upper bound.
    for i in 0 ..< 16:
      try:
        truncFile(rawPath(i))
        truncFile(escPath(i))
        truncFile(gridPath(i))
      except IOError, OSError: discard

  proc dbgRecordRead*(idx: int, ps: var ParserState,
                      buf: pointer, n: int) =
    if n <= 0: return
    try:
      appendBin(rawPath(idx), buf, n)
    except IOError, OSError: discard
    try:
      let p = cast[ptr UncheckedArray[byte]](buf)
      for i in 0 ..< n:
        feedByte(idx, ps, p[i])
    except IOError, OSError: discard

  proc dbgDumpGrid*(idx, rows, cols, curR, curC: int,
                    cellAt: proc(r, c: int): int32,
                    reverseAt: proc(r, c: int): bool = nil) =
    ## `cellAt` returns the wchar_t codepoint for (r,c).
    ## `reverseAt` (optional) reports whether the cell has SGR reverse on.
    try:
      truncFile(gridPath(idx))
      let f = open(gridPath(idx), fmAppend)
      defer: f.close()
      f.writeLine("# prawk-term-" & termIndex(idx) & " grid dump")
      f.writeLine("size " & $rows & "x" & $cols & "  cursor " &
                  $curR & "," & $curC)
      f.writeLine("--- text (Unicode-faithful) ---")
      for r in 0 ..< rows:
        var line = ""
        for c in 0 ..< cols:
          let cp = cellAt(r, c)
          if cp <= 0 or cp == 0x20:
            line.add(' ')
          elif cp < 0x20 or cp == 0x7F:
            line.add('?')
          else:
            line.add($Rune(cp))
        # Trim trailing spaces.
        var k = line.len
        while k > 0 and line[k - 1] == ' ': dec k
        line.setLen(k)
        f.writeLine(line)
      f.writeLine("--- non-ASCII cells (row,col -> U+XXXX) ---")
      for r in 0 ..< rows:
        for c in 0 ..< cols:
          let cp = cellAt(r, c)
          if cp > 0x7E or (cp > 0 and cp < 0x20):
            f.writeLine($r & "," & $c & " U+" & toHex(cp.int, 4) &
                        "  " & $Rune(cp))
      if reverseAt != nil:
        f.writeLine("--- reverse-video cells (Claude's fake cursors / badges) ---")
        for r in 0 ..< rows:
          for c in 0 ..< cols:
            if reverseAt(r, c):
              let cp = cellAt(r, c)
              let glyph =
                if cp <= 0 or cp == 0x20: "(space)"
                elif cp < 0x20: "(ctl)"
                else: $Rune(cp)
              f.writeLine($r & "," & $c & "  " & glyph)
    except IOError, OSError: discard

else:
  # Empty stubs so call sites compile unchanged.
  type ParserState* = object
  proc dbgInit*() = discard
  proc dbgRecordRead*(idx: int, ps: var ParserState,
                      buf: pointer, n: int) = discard
  proc dbgDumpGrid*(idx, rows, cols, curR, curC: int,
                    cellAt: proc(r, c: int): int32,
                    reverseAt: proc(r, c: int): bool = nil) = discard
