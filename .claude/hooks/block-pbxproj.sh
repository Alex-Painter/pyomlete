#!/bin/sh
# PreToolUse hook: refuse Edit/Write on Xcode project files. See ios/CLAUDE.md.
if grep -qE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*\.pbxproj"'; then
  echo "Blocked: never edit project.pbxproj by hand. Source files are picked up automatically (synchronized groups); change build settings, targets and capabilities in Xcode, or ask Alex to." >&2
  exit 2
fi
exit 0
