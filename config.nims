exec "bash scripts/prep-vendor.sh"

switch("path", "build/luiginim/src")
switch("mm", "arc")
switch("panics", "on")
switch("define", "lFreetype")
switch("passL", "-l:libfreetype.so.6")

when defined(release):
  switch("opt", "size")
  switch("passC", "-Os -ffunction-sections -fdata-sections -fno-strict-aliasing")
  switch("passL", "-s -Wl,--gc-sections -Wl,--as-needed")
