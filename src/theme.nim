import std/[os, strutils]
import luigi

type Palette* = object
  bg*, fg*, accent*, muted*, urgent*: uint32
  borderLight*, borderDark*, separator*: uint32
  codeKeyword*, codeString*, codeComment*, codeNumber*, codeOperator*: uint32

const gruvboxMaterialPsion* = Palette(
  bg:            0x32302f'u32,
  fg:            0xd4be98'u32,
  accent:        0x9253be'u32,
  muted:         0x7c6b9e'u32,
  urgent:        0xea6962'u32,
  borderLight:   0x3c3836'u32,
  borderDark:    0x252423'u32,
  separator:     0x46413e'u32,
  codeKeyword:   0xea6962'u32,
  codeString:    0xa9b665'u32,
  codeComment:   0x7c6f64'u32,
  codeNumber:    0xd8a657'u32,
  codeOperator:  0xd4be98'u32,
)

proc parseHex(s: string): uint32 =
  let t = s.strip().strip(chars = {'#'})
  if t.len == 6:
    result = uint32(parseHexInt(t))

proc loadPaletteFile(path: string, p: var Palette): bool =
  if not fileExists(path): return false
  for rawLine in lines(path):
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
  ui.theme.codePreprocessor = p.accent

proc loadTheme*() =
  var p = gruvboxMaterialPsion
  let path = getAppDir() / "themes" / "default.theme"
  discard loadPaletteFile(path, p)
  apply(p)
