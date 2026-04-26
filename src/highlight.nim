import std/[os, strutils, sets, tables]
import luigi, font, theme

type
  TokenKind* = enum
    tkDefault, tkKeyword, tkString, tkComment, tkNumber, tkOperator,
    tkProcName, tkTypeName, tkReturnType

  LangKind* = enum lkGeneric, lkNim

  Span* = object
    col*, n*: int
    kind*: TokenKind

  SyntaxRule* = object
    name*: string
    lang*: LangKind
    extensions*: seq[string]
    keywords*: HashSet[string]
    commentLine*: string
    commentOpen*, commentClose*: string
    stringDelims*: set[char]
    operators*: set[char]

const nimProcKeywords = ["proc", "func", "iterator", "template", "macro",
                         "method", "converter"].toHashSet

template embedSyntax(n: untyped): (string, string) =
  (astToStr(n), staticRead("../syntax/" & astToStr(n) & ".conf"))

const builtinSyntaxes*: array[4, (string, string)] = [
  embedSyntax(nim),
  embedSyntax(c),
  embedSyntax(python),
  embedSyntax(js),
]

var
  rules: seq[SyntaxRule]
  byExt: Table[string, int]   # extension -> index into rules

proc parseRule(name, body: string): SyntaxRule =
  result.name = name
  if name == "nim": result.lang = lkNim
  for raw in body.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip()
    let val = line[colon+1 .. ^1].strip()
    case key
    of "extensions":
      for raw in val.split(','):
        let s = raw.strip().toLowerAscii()
        if s.len > 0: result.extensions.add(s)
    of "comment_line":        result.commentLine  = val
    of "comment_block_open":  result.commentOpen  = val
    of "comment_block_close": result.commentClose = val
    of "string_delims":
      for c in val: result.stringDelims.incl(c)
    of "operators":
      for c in val: result.operators.incl(c)
    of "keywords":
      for kw in val.split({' ', '\t'}):
        if kw.len > 0: result.keywords.incl(kw)
    else: discard            # scope_* keys reserved for future tmTheme loader

proc loadAllSyntaxes*() =
  rules.setLen(0)
  byExt.clear()
  for (n, body) in builtinSyntaxes:
    rules.add(parseRule(n, body))
    let i = rules.len - 1
    for ext in rules[i].extensions:
      byExt[ext] = i

proc syntaxForPath*(path: string): ptr SyntaxRule =
  if path.len == 0 or rules.len == 0: return nil
  let ext = splitFile(path).ext.toLowerAscii.strip(chars = {'.'})
  if ext.len == 0: return nil
  if not byExt.hasKey(ext): return nil
  return addr rules[byExt[ext]]

proc isIdentStart(c: char): bool {.inline.} = c.isAlphaAscii or c == '_'
proc isIdentCont(c: char): bool {.inline.} = c.isAlphaNumeric or c == '_'

proc matchesAt(line: string, i: int, s: string): bool {.inline.} =
  if s.len == 0 or i + s.len > line.len: return false
  for k in 0 ..< s.len:
    if line[i + k] != s[k]: return false
  return true

proc tokenizeLine*(line: string, rule: ptr SyntaxRule,
                   prevState: uint8, spans: var seq[Span]): uint8 =
  ## Tokenizes one line. `prevState` 1 = inside a block comment from the
  ## previous line. Returns the trailing state for the next line.
  spans.setLen(0)
  if rule == nil:
    if line.len > 0:
      spans.add(Span(col: 0, n: line.len, kind: tkDefault))
    return 0

  var i = 0
  let n = line.len

  # --- continuation of a block comment from the previous line
  if prevState == 1'u8:
    if n == 0: return 1'u8
    let close = rule.commentClose
    var j = 0
    var closed = false
    while j < n:
      if close.len > 0 and matchesAt(line, j, close):
        j += close.len
        closed = true
        break
      inc j
    spans.add(Span(col: 0, n: j, kind: tkComment))
    i = j
    if not closed:
      return 1'u8

  # Per-line Nim-aware state. Tracks "next ident should be colored as X" and
  # whether we're inside a proc-def line (so `:` triggers return-type coloring
  # for both arg types in the params and the return type after `):`).
  var pendingKind = tkDefault
  var inProcDef = false

  while i < n:
    let c = line[i]

    # block comment open
    if rule.commentOpen.len > 0 and matchesAt(line, i, rule.commentOpen):
      let start = i
      var j = i + rule.commentOpen.len
      var closed = false
      while j < n:
        if rule.commentClose.len > 0 and matchesAt(line, j, rule.commentClose):
          j += rule.commentClose.len
          closed = true
          break
        inc j
      spans.add(Span(col: start, n: j - start, kind: tkComment))
      i = j
      if not closed:
        return 1'u8
      continue

    # line comment
    if rule.commentLine.len > 0 and matchesAt(line, i, rule.commentLine):
      spans.add(Span(col: i, n: n - i, kind: tkComment))
      i = n
      continue

    # string
    if c in rule.stringDelims:
      let delim = c
      let start = i
      inc i
      while i < n:
        if line[i] == '\\' and i + 1 < n:
          i += 2
          continue
        if line[i] == delim:
          inc i
          break
        inc i
      spans.add(Span(col: start, n: i - start, kind: tkString))
      continue

    # number (only if not in middle of identifier)
    if c.isDigit:
      let start = i
      inc i
      while i < n:
        let ch = line[i]
        if ch.isAlphaNumeric or ch == '.' or ch == '_': inc i
        else: break
      spans.add(Span(col: start, n: i - start, kind: tkNumber))
      continue

    # identifier / keyword
    if isIdentStart(c):
      let start = i
      inc i
      while i < n and isIdentCont(line[i]): inc i
      let word = line[start ..< i]
      if rule.keywords.contains(word):
        spans.add(Span(col: start, n: i - start, kind: tkKeyword))
        if rule.lang == lkNim:
          if word in nimProcKeywords:
            inProcDef = true
            pendingKind = tkProcName
          elif word == "type":
            pendingKind = tkTypeName
      elif pendingKind != tkDefault:
        spans.add(Span(col: start, n: i - start, kind: pendingKind))
        pendingKind = tkDefault
      # else: leave as default (no span needed; gap between spans paints default)
      continue

    # operator (single char)
    if c in rule.operators:
      spans.add(Span(col: i, n: 1, kind: tkOperator))
      if rule.lang == lkNim and inProcDef and c == ':':
        pendingKind = tkReturnType
      inc i
      continue

    # default: skip
    inc i

  return 0'u8

proc colorFor*(kind: TokenKind): uint32 {.inline.} =
  case kind
  of tkKeyword:    ui.theme.codePreprocessor   # luigi has no codeKeyword slot
  of tkString:     ui.theme.codeString
  of tkComment:    ui.theme.codeComment
  of tkNumber:     ui.theme.codeNumber
  of tkOperator:   ui.theme.codeOperator
  of tkProcName:   theme.currentPalette.codeKeyword
  of tkTypeName:   theme.currentPalette.codeType
  of tkReturnType: theme.currentPalette.codeReturnType
  of tkDefault:    ui.theme.codeDefault

proc paintLine*(painter: ptr Painter, r: Rectangle, line: string,
                rule: ptr SyntaxRule, prevState: uint8,
                spans: var seq[Span]) =
  ## Paints one line with the supplied tokenizer state. Caller should pass a
  ## reusable spans buffer to avoid per-call allocations in steady state.
  discard tokenizeLine(line, rule, prevState, spans)

  let (gW, _) = glyphDims()
  let bx = r.l

  # Pass 1: background-fill any gap with default color (only spans we kept
  # above are non-default tokens; gaps are default).
  var col = 0
  for s in spans:
    if s.col > col:
      let txt = line[col ..< s.col]
      let rect = Rectangle(l: bx + cint(col) * gW, r: r.r, t: r.t, b: r.b)
      drawString(painter, rect, txt.cstring, txt.len,
                 ui.theme.codeDefault, cint(ALIGN_LEFT), nil)
    let txt = line[s.col ..< s.col + s.n]
    let rect = Rectangle(l: bx + cint(s.col) * gW, r: r.r, t: r.t, b: r.b)
    drawString(painter, rect, txt.cstring, txt.len,
               colorFor(s.kind), cint(ALIGN_LEFT), nil)
    col = s.col + s.n
  if col < line.len:
    let txt = line[col ..< line.len]
    let rect = Rectangle(l: bx + cint(col) * gW, r: r.r, t: r.t, b: r.b)
    drawString(painter, rect, txt.cstring, txt.len,
               ui.theme.codeDefault, cint(ALIGN_LEFT), nil)

proc advanceState*(line: string, rule: ptr SyntaxRule,
                   prevState: uint8): uint8 =
  ## Cheap variant for the editor's lineStartStates cache: tokenize but
  ## discard spans, just return the trailing state.
  var tmp: seq[Span]
  return tokenizeLine(line, rule, prevState, tmp)
