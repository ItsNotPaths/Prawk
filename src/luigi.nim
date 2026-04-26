## Hand-rolled minimal Nim binding for nakst/luigi v1 single-header UI.
## Covers only the surface prawk uses; replaces the (broken) luiginim binding.
##
## Layouts are mirrored from vendor/luigi/luigi.h. `intptr_t` C fields are
## declared as Nim `int` (8 bytes on x64 to match), not `cint`.

import std/os

when not defined(linux):
  {.error: "prawk's luigi binding currently targets Linux only.".}

const luigiDir = currentSourcePath().parentDir().parentDir() / "vendor" / "luigi"

{.passC: "-DUI_LINUX -DUI_FREETYPE".}
{.passC: "-I\"" & luigiDir & "\"".}
{.passC: "-I\"" & (luigiDir / "freetype") & "\"".}
{.passL: "-lX11 -lm -l:libfreetype.so.6".}
{.compile: currentSourcePath().parentDir() / "luigi_impl.c".}

{.pragma: lH, header: "luigi.h".}

# ---------- enums and flag constants ----------

type Message* {.size: sizeof(cint), importc: "UIMessage", lH.} = enum
  msgPaint, msgLayout, msgDestroy, msgUpdate, msgAnimate, msgScrolled,
  msgGetWidth, msgGetHeight, msgFindByPoint, msgClientParent,
  msgInputEventsStart,
  msgLeftDown, msgLeftUp, msgMiddleDown, msgMiddleUp, msgRightDown, msgRightUp,
  msgKeyTyped, msgMouseMove, msgMouseDrag, msgMouseWheel, msgClicked,
  msgGetCursor, msgPressedDescendent,
  msgInputEventsEnd,
  msgValueChanged, msgTableGetItem, msgCodeGetMarginColor, msgCodeDecorateLine,
  msgWindowClose, msgTabSelected, msgWindowDropFiles, msgWindowActivate,
  msgUser

const
  ELEMENT_V_FILL*    = uint32(1) shl 16
  ELEMENT_H_FILL*    = uint32(1) shl 17
  ELEMENT_TAB_STOP*  = uint32(1) shl 20
  ELEMENT_HIDE*      = uint32(1) shl 29

  PANEL_HORIZONTAL*  = uint32(1) shl 0
  PANEL_GRAY*        = uint32(1) shl 2
  PANEL_EXPAND*      = uint32(1) shl 4

  BUTTON_SMALL*      = uint32(1) shl 0
  BUTTON_CAN_FOCUS*  = uint32(1) shl 2
  BUTTON_CHECKED*    = uint32(1) shl 15

  SPLIT_PANE_VERTICAL* = uint32(1) shl 0

  WINDOW_MENU*       = uint32(1) shl 0

  ALIGN_LEFT*        = cint(1)
  ALIGN_RIGHT*       = cint(2)
  ALIGN_CENTER*      = cint(3)

# Linux luigi sets these from XK_* keysym values; freed at link time.
let
  KEYCODE_A*         {.importc: "UI_KEYCODE_A",         lH.}: cint
  KEYCODE_BACKSPACE* {.importc: "UI_KEYCODE_BACKSPACE", lH.}: cint
  KEYCODE_DELETE*    {.importc: "UI_KEYCODE_DELETE",    lH.}: cint
  KEYCODE_DOWN*      {.importc: "UI_KEYCODE_DOWN",      lH.}: cint
  KEYCODE_END*       {.importc: "UI_KEYCODE_END",       lH.}: cint
  KEYCODE_ENTER*     {.importc: "UI_KEYCODE_ENTER",     lH.}: cint
  KEYCODE_ESCAPE*    {.importc: "UI_KEYCODE_ESCAPE",    lH.}: cint
  KEYCODE_HOME*      {.importc: "UI_KEYCODE_HOME",      lH.}: cint
  KEYCODE_INSERT*    {.importc: "UI_KEYCODE_INSERT",    lH.}: cint
  KEYCODE_LEFT*      {.importc: "UI_KEYCODE_LEFT",      lH.}: cint
  KEYCODE_RIGHT*     {.importc: "UI_KEYCODE_RIGHT",     lH.}: cint
  KEYCODE_TAB*       {.importc: "UI_KEYCODE_TAB",       lH.}: cint
  KEYCODE_UP*        {.importc: "UI_KEYCODE_UP",        lH.}: cint

template KEYCODE_LETTER*(x: char): int = int(KEYCODE_A) + (int(x) - int('A'))

# ---------- structs ----------

type
  Rectangle* {.bycopy, importc: "UIRectangle", lH.} = object
    l*, r*, t*, b*: cint

  Theme* {.bycopy, importc: "UITheme", lH.} = object
    panel1*, panel2*, selected*, border*: uint32
    text*, textDisabled*, textSelected*: uint32
    buttonNormal*, buttonHovered*, buttonPressed*, buttonDisabled*: uint32
    textboxNormal*, textboxFocused*: uint32
    codeFocused*, codeBackground*, codeDefault*, codeComment*,
      codeString*, codeNumber*, codeOperator*, codePreprocessor*: uint32

  Painter* {.bycopy, importc: "UIPainter", lH.} = object
    clip*: Rectangle
    bits*: pointer
    width*, height*: cint

  # We only ever read glyphWidth/glyphHeight (the first two fields). The rest
  # of UIFont varies with -DUI_FREETYPE; leaving it off shrinks the Nim view
  # but is safe because we never instantiate or sizeof() Font from Nim.
  Font* {.bycopy, importc: "UIFont", lH.} = object
    glyphWidth*, glyphHeight*: cint

  Shortcut* {.bycopy, importc: "UIShortcut", lH.} = object
    code*: int                 # C: intptr_t
    ctrl*, shift*, alt*: bool
    invoke*: proc (cp: pointer) {.cdecl.}
    cp*: pointer

  KeyTyped* {.bycopy, importc: "UIKeyTyped", lH.} = object
    text*: cstring
    textBytes*: cint
    code*: int                 # C: intptr_t

  ElementMessageProc* = proc (e: ptr Element; m: Message; di: cint;
                              dp: pointer): cint {.cdecl.}

  Element* {.bycopy, importc: "UIElement", lH.} = object
    flags*: uint32
    id*: uint32
    parent*: ptr Element
    next*: ptr Element
    children*: ptr Element
    window*: ptr Window
    bounds*: Rectangle
    clip*: Rectangle
    cp*: pointer
    messageClass*: ElementMessageProc
    messageUser*: ElementMessageProc
    cClassName*: cstring

  Window* {.bycopy, importc: "UIWindow", lH.} = object
    e*: Element
    dialog*: ptr Element
    shortcuts: ptr Shortcut
    shortcutCount, shortcutAllocated: csize_t
    scale: cfloat
    bits: pointer
    width, height: cint
    next*: ptr Window
    hovered*, pressed*, focused*: ptr Element
    dialogOldFocus: ptr Element
    pressedButton: cint
    cursorX*, cursorY*: cint
    cursorStyle: cint
    textboxModifiedFlag: bool
    ctrl*, shift*, alt*: bool
    # X11 fields and remainder follow in C; we never read them from Nim, and
    # we never instantiate Window, so omitting them is fine.

  Panel*     {.bycopy, importc: "UIPanel",     lH.} = object
    e*: Element
  SplitPane* {.bycopy, importc: "UISplitPane", lH.} = object
    e*: Element
  Label*     {.bycopy, importc: "UILabel",     lH.} = object
    e*: Element
  Menu*      {.bycopy, importc: "UIMenu",      lH.} = object
    e*: Element
  Button*    {.bycopy, importc: "UIButton",    lH.} = object
    e*: Element
    label*: cstring
    labelBytes*: int           # C: ptrdiff_t
    invoke*: proc (cp: pointer) {.cdecl.}

  StringSelection* {.bycopy, importc: "UIStringSelection", lH.} = object

  UI* {.bycopy, importc: "struct {} __unused", lH.} = object
    # Marker only; the global `ui` is reached via importc below.
    discard

# ---------- the singleton globals from luigi.c ----------

# luigi declares `ui` as an unnamed-struct global only visible inside the
# UI_IMPLEMENTATION translation unit. luigi_impl.c exposes accessors.
proc prawk_ui_windows():     ptr ptr Window {.importc, cdecl.}
proc prawk_ui_theme():       ptr Theme      {.importc, cdecl.}
proc prawk_ui_active_font(): ptr ptr Font   {.importc, cdecl.}

type UiAccess* = object
template windows*(_: UiAccess): ptr Window     = prawk_ui_windows()[]
template theme*(_: UiAccess): var Theme        = prawk_ui_theme()[]
template activeFont*(_: UiAccess): ptr Font    = prawk_ui_active_font()[]
let ui*: UiAccess = UiAccess()

# ---------- procs ----------

proc initialise*() {.cdecl, lH, importc: "UIInitialise".}
proc messageLoop*(): cint {.cdecl, lH, importc: "UIMessageLoop".}

proc elementCreate*(bytes: csize_t; parent: ptr Element; flags: uint32;
                    message: ElementMessageProc; cClassName: cstring): ptr Element
                    {.cdecl, lH, importc: "UIElementCreate".}
proc elementMessage*(e: ptr Element; message: Message; di: cint; dp: pointer): cint
                    {.cdecl, lH, importc: "UIElementMessage".}
proc elementFocus*(e: ptr Element)              {.cdecl, lH, importc: "UIElementFocus".}
proc elementRepaint*(e: ptr Element; region: ptr Rectangle)
                    {.cdecl, lH, importc: "UIElementRepaint".}
proc elementRefresh*(e: ptr Element)             {.cdecl, lH, importc: "UIElementRefresh".}
proc elementDestroy*(e: ptr Element)             {.cdecl, lH, importc: "UIElementDestroy".}
proc elementMove*(e: ptr Element; bounds: Rectangle; alwaysLayout: bool)
                    {.cdecl, lH, importc: "UIElementMove".}
proc elementAnimate*(e: ptr Element; stop: bool): bool
                    {.cdecl, lH, importc: "UIElementAnimate".}

proc windowCreate*(owner: ptr Window; flags: uint32; cTitle: cstring;
                   width, height: cint): ptr Window
                  {.cdecl, lH, importc: "UIWindowCreate".}
proc windowRegisterShortcut*(window: ptr Window; shortcut: Shortcut)
                  {.cdecl, lH, importc: "UIWindowRegisterShortcut".}

proc panelCreate*(parent: ptr Element; flags: uint32): ptr Panel
                  {.cdecl, lH, importc: "UIPanelCreate".}
proc splitPaneCreate*(parent: ptr Element; flags: uint32; weight: cfloat): ptr SplitPane
                  {.cdecl, lH, importc: "UISplitPaneCreate".}
proc labelCreate*(parent: ptr Element; flags: uint32; label: cstring;
                  labelBytes: int = -1): ptr Label
                  {.cdecl, lH, importc: "UILabelCreate".}
proc buttonCreate*(parent: ptr Element; flags: uint32; label: cstring;
                   labelBytes: int = -1): ptr Button
                  {.cdecl, lH, importc: "UIButtonCreate".}

proc menuCreate*(parent: ptr Element; flags: uint32): ptr Menu
                  {.cdecl, lH, importc: "UIMenuCreate".}
proc menuAddItem*(menu: ptr Menu; flags: uint32; label: cstring;
                  labelBytes: int = -1;
                  invoke: proc (cp: pointer) {.cdecl.};
                  cp: pointer = nil)
                  {.cdecl, lH, importc: "UIMenuAddItem".}
proc menuShow*(menu: ptr Menu) {.cdecl, lH, importc: "UIMenuShow".}

proc painterPixels*(p: ptr Painter): ptr UncheckedArray[uint32] {.inline.} =
  cast[ptr UncheckedArray[uint32]](p.bits)

proc drawBlock*(p: ptr Painter; r: Rectangle; color: uint32)
                  {.cdecl, lH, importc: "UIDrawBlock".}
proc drawInvert*(p: ptr Painter; r: Rectangle)
                  {.cdecl, lH, importc: "UIDrawInvert".}
proc drawBorder*(p: ptr Painter; r: Rectangle; borderColor: uint32;
                 borderSize: Rectangle)
                  {.cdecl, lH, importc: "UIDrawBorder".}
proc drawString*(p: ptr Painter; r: Rectangle; s: cstring; bytes: int = -1;
                 color: uint32; align: cint; selection: ptr StringSelection = nil)
                  {.cdecl, lH, importc: "UIDrawString".}
proc drawStringHighlighted*(p: ptr Painter; r: Rectangle; s: cstring;
                            bytes: int = -1; tabSize: cint): cint
                  {.cdecl, lH, importc: "UIDrawStringHighlighted".}
proc measureStringWidth*(s: cstring; bytes: int = -1): cint
                  {.cdecl, lH, importc: "UIMeasureStringWidth".}

# prawk: draws an arbitrary codepoint via FreeType (no glyph cache). Used for
# the terminal cells with non-ASCII chars; luigi's UIDrawGlyph clamps to 0-127.
proc drawGlyphCp*(p: ptr Painter; x, y: cint; cp: cint; color: uint32)
                  {.cdecl, importc: "prawk_draw_glyph_cp".}

proc fontCreate*(cPath: cstring; size: uint32): ptr Font
                  {.cdecl, lH, importc: "UIFontCreate".}
proc fontActivate*(font: ptr Font): ptr Font
                  {.cdecl, lH, importc: "UIFontActivate".}
