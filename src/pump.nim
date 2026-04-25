import luigi
import term

proc usleep(us: cuint): cint {.importc, header: "<unistd.h>", discardable.}

proc pumpMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if m == msgAnimate:
    drainAll()
    usleep(20_000)  # ~50 Hz cap so the animate spin doesn't peg a core
  return 0

proc startPump*(window: ptr Window) =
  let e = elementCreate(csize_t(sizeof(Element)), addr window.e, ELEMENT_HIDE,
                        pumpMessage, "Pump")
  discard elementAnimate(e, false)
