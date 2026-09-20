# CMD-X

Small native macOS AppKit menu bar utility. Keep implementation focused; no dependencies or unrelated refactoring.

- Preserve other changes. Read the current branch before editing; never force-push.
- Never delete/overwrite files to implement cutting. Finder performs moves, without replacing existing destination items.
- Only intercept Finder file-view shortcuts. Preserve text editing and other apps.
- Keep cut intent tied to the clipboard generation; never overwrite newer clipboard contents.
- Keep the indicator populated until Finder confirms completion; retain failures after partial success.
- No GitHub Actions. Builds and tests are sparing; never claim macOS verification from Linux.
- All build outputs belong under `Build/` in this repository. If a build is necessary, pass `-derivedDataPath "$PWD/Build/DerivedData"`. Use existing Xcode. Do not launch extra Xcode windows or simulators.
- A macOS smoke-test checklist and bounded local Codex handoff live in `docs/MACOS-CHECK.md`.
