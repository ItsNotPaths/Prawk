switch("mm", "arc")
switch("panics", "on")

when defined(release):
  switch("opt", "size")
  switch("passC", "-Os -ffunction-sections -fdata-sections -fno-strict-aliasing")
  switch("passL", "-s -Wl,--gc-sections -Wl,--as-needed")
