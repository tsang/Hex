---
"hex-app": patch
---

Fix crash when starting a recording with Audio set to "Pause Media": AppleScript media-pause scripts now run in an out-of-process osascript helper, containing an OS AppleScript component segfault inside a child process instead of taking down Hex
