# BatteryKeeper GUI

A Swift/SwiftUI menu bar app that wraps the `battery` CLI. Build and install
with `./gui/build.sh --install` from the repository root; run the tests with
`swift test --package-path ./gui`.

The GUI never names `smc` commands and never calls `pmset` on its own behalf:
every privileged or scripted operation runs through `BatteryCore`'s
`BatteryCLI`, the only visudo consumer in the codebase. What the GUI does read
in-process is IOKit's public power-source data, which macOS publishes to every
process — that split is what this document describes.

## The refresh pipeline

Nothing in the GUI polls on a timer. The pipeline is event-driven end to end:

1. **`PowerEventMonitor`** subscribes to three things macOS already maintains:
   IOKit's power-source notification (fires when the reported percentage,
   estimate, or adapter state moves — and stays silent while a pack sits
   parked at its maintain limit), `NSWorkspace.didWakeNotification`, and
   `NSProcessInfoPowerStateDidChange` (Low Power Mode).
2. Every IOKit callback reads a **`PowerSnapshot`** in-process (see
   `PowerSourceReader`): percentage, charging, adapter, and the
   time-remaining estimate, at zero subprocess cost. The other two sources
   carry no snapshot — the changes they announce are invisible to IOKit's
   battery fields.
3. Events landing within **`minimumRefreshInterval`** (30s) of the previous
   refresh fold into one refresh at the end of the interval. The constant is
   both the folding window and the floor: no event-driven refresh runs sooner
   than 30s after the last one, so a system that reports power-state flaps
   every few seconds costs one CLI run per interval, not one per flap.
4. **`AppState.refreshAsync`** first patches the display from the snapshot
   (so the icon and popover never wait on the floor), then compares the
   snapshot against `lastFullSnapshot` — the reading the last successful
   `battery status_csv` produced. Matching means nothing the CLI reports has
   moved, and the refresh stops there. Only a real change runs the CLI, and
   the result becomes the next baseline.
5. A **safety-net poll** (every 5 minutes) and every user action read the CLI
   in full regardless, bypassing both the snapshot comparison and the floor.
   These catch what no event announces: a `battery maintain` typed in a
   terminal, a calibration killed from another shell, an uninstalled CLI.

## Where each piece of data comes from

| Data | Source | Role |
| --- | --- | --- |
| Percentage, charging now, adapter attached, time-remaining estimate | IOKit, in-process (`PowerSourceReader`) | Display only, plus the skip decision. Same source `pmset` reads; no SMC, nothing privileged. |
| Maintain value | `status_csv` column 5 | CLI-owned: it lives in the CLI's tracker file. |
| Low Power Mode | `status_csv` column 7 (+ pmset for old CLIs) | CLI-owned; Low Power Mode changes arrive via the power-state event, which always reads the CLI in full. |
| Live power state (charging / discharging / not charging) | `status_csv` column 8 | The only witness of a force-discharge; IOKit cannot see the block. |
| Charging-control backend (native / tahoe / legacy / unsupported) | `status_csv` column 9 | The macOS 27 compatibility signal. |
| Charging / discharging *permission* flags | `status_csv` columns 3–4 | Kept for CLIs older than v1.3.7, whose pmset fallback in `ProcessBatteryCLI` is untouched. |
| Every action: maintain, charge, discharge, low on/off, calibrate | CLI subcommands | The GUI never performs control itself. |

The fast path never *replaces* CLI data — it is a display cache plus a gate.
A reading the CLI has not confirmed is never persisted, and CLI-derived state
that IOKit cannot see keeps its value from the last full read.

## Invariants worth keeping

- The baseline is built **from** the CLI's own status (`PowerSnapshot(status:)`),
  never from IOKit alone, so the comparison is CLI-truth against IOKit-now.
- A failed CLI read clears the baseline, so the next event retries rather
  than skipping against a stale reading.
- Cycle completion and the auto low-power rule run on full reads only: a
  level that has not moved can neither complete a cycle nor cross a threshold.
- The failure mode of the whole fast path is graceful: if IOKit and the CLI
  ever disagree, every event just looks like a real change and the GUI falls
  back to the pre-optimization behavior of one read per event.
- `IOPSGetTimeRemainingEstimate()` answers in **seconds** despite its header
  docs claiming minutes (`PowerSourceReader.estimateMinutes` documents the
  cross-check). -1 and -2 mean "no estimate" and map to nil, never to a
  countdown.

Changes here do not need a `battery.sh` version bump (the GUI carries its own
`APP_VERSION` in `build.sh`), and no `visudoconfig` change is ever triggered
by this directory.
