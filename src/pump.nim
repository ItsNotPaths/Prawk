import luigi
import term, clshell, menubar, editor, config

proc usleep(us: cuint): cint {.importc, header: "<unistd.h>", discardable.}

var blinkTicks: int = 0

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
    usleep(20_000)  # ~50 Hz cap so the animate spin doesn't peg a core
  return 0

proc startPump*(window: ptr Window) =
  let e = elementCreate(csize_t(sizeof(Element)), addr window.e, ELEMENT_HIDE,
                        pumpMessage, "Pump")
  discard elementAnimate(e, false)
