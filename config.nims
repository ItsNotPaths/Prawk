switch("mm", "arc")
switch("panics", "on")

when defined(release):
  switch("opt", "size")
  switch("passC", "-Os -flto -ffunction-sections -fdata-sections -fno-strict-aliasing -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector")
  switch("passL", "-flto -s -Wl,--gc-sections -Wl,--as-needed")
