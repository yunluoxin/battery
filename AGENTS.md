This repository contains software that limits the battery charging level of apple silicon macbooks.

## Project structure

- `./battery.sh` is the main CLI binary used under the hood
- `./setup.sh` is the setup script for the binary
- `./update.sh` is the script used to update the binary
- `./gui/` contains a Swift/SwiftUI menu bar app that wraps around the CLI (`./gui/build.sh` builds and bundles it, `swift test --package-path ./gui` runs its tests); `./gui/README.md` documents the refresh pipeline and which data is read from IOKit in-process versus from the CLI
- `./dist` contains precompiled binaries that are shipped with the CLI

## Development flow

- any changes made to `battery.sh` must also increment the version number at the top of `battery.sh` as this is what the update command relies on
- any changes to `smc` commands must update the `visudoconfig` variable in `battery.sh` as this updates the visudo entry on the client device to make sure smc may run commands without sudo
- the GUI never names `smc` commands itself — it runs the `battery` CLI through `BatteryCore`'s `BatteryCLI`, which is the only visudo consumer — so a `visudoconfig` change needs no matching edit anywhere under `./gui/`
- any new user-facing string in `./gui` must be wrapped in `l10n.t` (or `l10n.f` for a format string) and added to every `Resources/*.lproj/Localizable.strings`; the key is the English text, and a missing entry falls back to English, so an untranslated key shows up in English rather than as a raw key
- `l10n.f` format specifiers must match the argument type — `%d` for numbers, `%@` for strings — because `String(format:)` traps at runtime on a mismatch
- adding a language means adding a `Resources/<code>.lproj/Localizable.strings` and a case to `AppLanguage` in `gui/Sources/BatteryCore/AppLanguage.swift`; `build.sh` copies whatever `.lproj` directories exist, and fails the build if there are none
- changes under `./gui` do not need the `battery.sh` version bump — the GUI carries its own `APP_VERSION` in `gui/build.sh`

## Mantatory checks

Before finishing any task, make sure that you:

- do a sanity check for bugs
- check that comments still reflect the changed code
- run `./gui/build.sh --install` from the project root and make sure it succeeds — it compiles the GUI, bundles the app, and installs it into `/Applications` so the user can test the change
