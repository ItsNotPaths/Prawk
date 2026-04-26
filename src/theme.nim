import std/[os, strutils, algorithm]
import luigi

type Palette* = object
  bg*, fg*, accent*, muted*, urgent*: uint32
  borderLight*, borderDark*, separator*: uint32
  codeKeyword*, codeString*, codeComment*, codeNumber*, codeOperator*: uint32
  codeType*, codeReturnType*: uint32

var currentPalette*: Palette

# Gruvbox Material Dark — mirrors sainnhe's Sublime color-scheme so the
# baked-in fallback matches themes/default.theme.
const gruvboxMaterialDark* = Palette(
  bg:             0x292828'u32,
  fg:             0xd4be98'u32,
  accent:         0x9253be'u32,
  muted:          0x928374'u32,
  urgent:         0xea6962'u32,
  borderLight:    0x504945'u32,
  borderDark:     0x32302f'u32,
  separator:      0x45403d'u32,
  codeKeyword:    0xd3869b'u32,
  codeString:     0xd8a657'u32,
  codeComment:    0x928374'u32,
  codeNumber:     0xd3869b'u32,
  codeOperator:   0xe78a4e'u32,
  codeType:       0xa9b665'u32,
  codeReturnType: 0x89b482'u32,
)

var
  activeTheme*: string = "default"
  discoveredThemes: seq[string]

proc themesDir(): string = getAppDir() / "themes"

proc discoverThemes*() =
  discoveredThemes.setLen(0)
  let dir = themesDir()
  if not dirExists(dir): return
  for kind, path in walkDir(dir, relative = true):
    if kind != pcFile: continue
    let (_, name, ext) = splitFile(path)
    if ext == ".theme" and name.len > 0:
      discoveredThemes.add(name)
  sort(discoveredThemes, system.cmp)

proc parseHex(s: string): uint32 =
  let t = s.strip().strip(chars = {'#'})
  if t.len == 6:
    result = uint32(parseHexInt(t))

proc parsePalette*(content: string, p: var Palette): bool =
  if content.len == 0: return false
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip()
    let val = parseHex(line[colon+1 .. ^1])
    case key
    of "bg":            p.bg = val
    of "fg":            p.fg = val
    of "accent":        p.accent = val
    of "muted":         p.muted = val
    of "urgent":        p.urgent = val
    of "border_light":  p.borderLight = val
    of "border_dark":   p.borderDark = val
    of "separator":     p.separator = val
    of "code_keyword":  p.codeKeyword = val
    of "code_string":   p.codeString = val
    of "code_comment":  p.codeComment = val
    of "code_number":   p.codeNumber = val
    of "code_operator": p.codeOperator = val
    of "code_type":     p.codeType = val
    of "code_return_type": p.codeReturnType = val
    else: discard
  return true

proc apply(p: Palette) =
  ui.theme.panel1          = p.bg
  ui.theme.panel2          = p.borderLight
  ui.theme.selected        = p.accent
  ui.theme.border          = p.borderDark
  ui.theme.text            = p.fg
  ui.theme.textDisabled    = p.muted
  ui.theme.textSelected    = p.bg
  ui.theme.buttonNormal    = p.borderLight
  ui.theme.buttonHovered   = p.separator
  ui.theme.buttonPressed   = p.accent
  ui.theme.buttonDisabled  = p.borderDark
  ui.theme.textboxNormal   = p.borderLight
  ui.theme.textboxFocused  = p.separator
  ui.theme.codeFocused     = p.borderLight
  ui.theme.codeBackground  = p.bg
  ui.theme.codeDefault     = p.fg
  ui.theme.codeComment     = p.codeComment
  ui.theme.codeString      = p.codeString
  ui.theme.codeNumber      = p.codeNumber
  ui.theme.codeOperator    = p.codeOperator
  ui.theme.codePreprocessor = p.codeKeyword
  currentPalette = p

proc themeNames*(): seq[string] =
  discoverThemes()
  result = discoveredThemes

proc loadThemeByName*(name: string): bool =
  let path = themesDir() / (name & ".theme")
  if not fileExists(path): return false
  var body: string
  try: body = readFile(path)
  except IOError: return false
  var p = gruvboxMaterialDark
  discard parsePalette(body, p)
  apply(p)
  activeTheme = name
  return true

proc loadInitialTheme*() =
  discoverThemes()
  if not loadThemeByName(activeTheme):
    apply(gruvboxMaterialDark)
    activeTheme = "default"

proc repaintAllWindows*() =
  var w = cast[ptr Window](ui.windows)
  while w != nil:
    elementRepaint(addr w.e, nil)
    w = w.next
