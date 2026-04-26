import luigi
import term, clshell, menubar, editor, config, minimap

proc usleep(us: cuint): cint {.importc, header: "<unistd.h>", discardable.}

var
  blinkTicks: int = 0
  lastMinimapTop: int = -1
  lastMinimapBuf: pointer = nil
  lastMinimapLines: int = -1
  lastMinimapDirty: int = high(int)

proc pumpMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if m == msgAnimate:
    clShellDrain()
    drainAll()
    clTickShift(e.window)
    if clShellRunning() and theMenubar != nil:
      elementRepaint(addr theMenubar.e, nil)
    inc blinkTicks
    if blinkTicks >= 30:    # ~600ms at 50 Hz
      blinkTicks = 0
      cursorBlinkOn = not cursorBlinkOn
      if theEditor != nil and e.window != nil and
         e.window.focused == (addr theEditor.e) and
         activeMode(theEditor) == cmNormal:
        elementRepaint(addr theEditor.e, nil)
    # Minimap tracks editor scroll, edits, and tab/file switches. Poll the
    # state each tick; repaint only when something actually changed so we
    # don't churn frames during idle. Lines+dirtyFromRow catch in-place
    # text changes (load-file, paste, typed input) where buf ptr doesn't
    # move and topLine often stays at 0.
    if theMinimap != nil and theMinimap.visible and theEditor != nil:
      let buf = activeBuf(theEditor)
      let bp     = cast[pointer](buf)
      let top    = if buf != nil: bufTopLine(buf) else: 0
      let nLines = if buf != nil: bufLines(buf).len else: 0
      let dirty  = if buf != nil: bufDirtyFromRow(buf) else: high(int)
      if bp != lastMinimapBuf or top != lastMinimapTop or
         nLines != lastMinimapLines or dirty != lastMinimapDirty:
        lastMinimapBuf   = bp
        lastMinimapTop   = top
        lastMinimapLines = nLines
        lastMinimapDirty = dirty
        elementRepaint(addr theMinimap.e, nil)
    usleep(20_000)  # ~50 Hz cap so the animate spin doesn't peg a core
  return 0

proc startPump*(window: ptr Window) =
  let e = elementCreate(csize_t(sizeof(Element)), addr window.e, ELEMENT_HIDE,
                        pumpMessage, "Pump")
  discard elementAnimate(e, false)
