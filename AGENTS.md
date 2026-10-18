# AGENTS.md

## Per-developer build settings

`DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` are per-developer and live outside the project file:

- `Config/Base.xcconfig` (committed) is the project-level base configuration. It holds placeholder values and includes `Local.xcconfig`.
- `Config/Local.xcconfig` (git-ignored) holds each developer's real values. `Config/Local.xcconfig.example` is the template.

Rules:

- Never set or commit `DEVELOPMENT_TEAM` or `PRODUCT_BUNDLE_IDENTIFIER` in `Construe.xcodeproj/project.pbxproj`. A value there overrides the xcconfig.
- Picking a team in Xcode's Signing & Capabilities tab writes it back into `project.pbxproj`. If that happens, remove it before committing.
- Never commit `Config/Local.xcconfig`. Check `git status` before committing, because Xcode auto-stages new files.
- New per-developer settings (e.g. app group or iCloud container IDs) go in the same place: a placeholder in `Base.xcconfig` and the real value in `Local.xcconfig`, plus the example file.
