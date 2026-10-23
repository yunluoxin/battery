# Native charge control on macOS 27

New firmware no longer exposes the old CHTE / CH0B charge-inhibition keys.
The CLI uses this actuator when those keys are unavailable. It never substitutes
adapter cutoff for charge inhibition.

Install the CLI, actuator, sudo rules and LaunchDaemon together from this checkout:

```sh
./setup.sh --local
./gui/build.sh --install
```

The upstream script-only updater does not include this backend. The CLI refuses
that update path while the native actuator is installed; use the complete local
installer to update it.

## Behavior

The existing CLI owns percentage/voltage decisions. For `maintain 60-70`, it stops
charging at 70% or above and resumes below 60%, retaining the previous state
inside the range. Stopping charging does not force the battery to discharge down
to the range. The adapter continues supplying the Mac.

The root service holds a native `ChargeCtrlPolicy` under its own PID. `off` uses
a low target with `drain=false`; `on` releases that inhibition. Using a fixed 70%
native target alone would not preserve the CLI's 60–70% hysteresis.

While active, the service pauses the system's manual charging limit and retains
its original enabled state. `battery maintain stop` removes BatteryKeeper's
policy and restores that state. Other system policies are retained; conflicting
policies cause an explicit failure rather than an adapter-cutoff fallback.

This uses private macOS behavior, verified on the local macOS 27 installation.
Policy changes require a restart of `powerd`, limited to actual changes and spaced
at least 11 seconds apart. Status is checked against the policies accepted by the
system. A subsequent OS update can change these interfaces. Preference writes
and system policy changes do not share an atomic transaction; concurrent changes
are checked and reported, but cannot be made fully atomic through this interface.

## Diagnostics and recovery

```sh
battery status_csv
sudo /usr/local/co.palokaj.battery/charge-control status
pmset -g battlimit
tail -n 50 /var/log/batterykeeper-charge-control.log
```

The CSV appends the backend (`native`, `tahoe`, `legacy`, or `unavailable`) in
column 9. The third column is charging permission, not instantaneous current.
Some sandboxed diagnostic sessions cannot read the system policy list.

To release BatteryKeeper's policy and restore the system manual-limit setting:

```sh
battery maintain stop
```

The actuator's fixed state directory is `/var/db/batterykeeper-charge-control`,
owned by root with mode 0700. Do not delete it while control is active: it contains
the information required to restore the original system state.

## Checks

```sh
bash native/build.sh --test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
swift test --package-path gui
```

The native tests validate policy preservation, conflict detection and status
verification without changing power settings. Real hardware checks must also
verify battery current and adapter input; cached `ioreg` readings alone can lag
behind an actual policy change.
