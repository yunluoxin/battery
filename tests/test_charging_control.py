"""Exercise shell control detection without accessing hardware or sudo."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "battery.sh").read_text()


def function(name):
    return re.search(r"^function " + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S).group()


def action_block(name):
    return re.search(r'^if \[\[ "\$action" == "' + name + r'" \]\]; then\n.*?^fi$', SOURCE, re.M | re.S).group()


class ChargingControlTests(unittest.TestCase):
    def run_control(self, command, **values):
        names = [
            "valid_percentage", "require_charging_control", "set_charging_control",
            "enable_charging", "disable_charging", "disable_discharging", "enable_discharging",
            "apply_percentage_control",
        ]
        script = "\n".join(function(name) for name in names) + r'''
charging_backend="${TEST_BACKEND:-native}"
native_binary=/unused/charge-control
smc_supports_adapter_chie=true
smc_supports_adapter_ch0i=false
smc_supports_adapter_ch0j=false
log() { :; }
get_smc_charging_status() { printf '%s\n' "${TEST_STATE:-enabled}"; }
get_battery_percentage() { printf '%s\n' "${TEST_PERCENT:-65}"; }
change_magsafe_led_color() { :; }
sudo() { printf 'native:%s\n' "$3"; return "${NATIVE_EXIT:-0}"; }
smc_write_hex() {
    printf 'smc:%s:%s\n' "$1" "$2"
    if [[ "$1" == "${SMC_FAIL_KEY:-}" ]]; then return 23; fi
}
'''
        return subprocess.run(
            ["/bin/bash", "-c", script + "\n" + command],
            env=dict(os.environ, **{key: str(value) for key, value in values.items()}),
            capture_output=True, text=True,
        )

    def run_read(self, output, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            smc = Path(directory) / "smc"
            smc.write_text("#!/bin/bash\nprintf '%s\\n' \"$SMC_OUTPUT\"\nexit \"$SMC_EXIT\"\n")
            smc.chmod(0o755)
            environment = dict(os.environ, SMC_OUTPUT=output, SMC_EXIT=str(exit_code), SMC_PATH=str(smc))
            return subprocess.run(
                ["/bin/bash", "-c", 'smc_binary="$SMC_PATH"\n' + function("smc_read_hex") + '\nsmc_read_hex CHTE'],
                env=environment, capture_output=True, text=True,
            )

    def test_valid_bytes_are_normalized(self):
        result = self.run_read("  CHTE  [hex_]  (bytes 01 00 00 00)")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "01000000")

    def test_no_data_is_not_a_supported_control(self):
        result = self.run_read("  CHTE  [    ]  no data")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_iokit_error_is_not_a_disabled_charging_flag(self):
        result = self.run_read("Error: SMCReadKey() = e00002c1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_failed_process_cannot_supply_successful_bytes(self):
        result = self.run_read("  CHTE  [hex_]  (bytes 00 00 00 00)", exit_code=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_multiple_byte_records_are_not_a_single_smc_value(self):
        result = self.run_read("CHTE (bytes 00 00)\nCHTE (bytes 00)")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_native_dispatch_preserves_control_failures(self):
        for command in ["on", "off", "reset"]:
            with self.subTest(command=command):
                result = self.run_control(
                    'set_charging_control "$TEST_COMMAND"',
                    TEST_COMMAND=command, NATIVE_EXIT=17,
                )
                self.assertEqual(result.returncode, 17)
                self.assertEqual(result.stdout.splitlines(), [f"native:{command}"])

    def test_failed_native_enable_does_not_continue_with_adapter_writes(self):
        result = self.run_control("enable_charging", NATIVE_EXIT=17)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ["native:on"])

    def test_percentage_band_has_60_70_hysteresis(self):
        for percent in [59, 60, 69, 70, 90]:
            for state in ["enabled", "disabled"]:
                with self.subTest(percent=percent, state=state):
                    result = self.run_control(
                        'apply_percentage_control "$TEST_PERCENT" 60 70',
                        TEST_PERCENT=percent, TEST_STATE=state,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = "off" if percent >= 70 else (
                        "on" if percent < 60 or state == "enabled" else "off"
                    )
                    writes = [f"native:{expected}"]
                    if expected == "on":
                        writes.append("smc:CHIE:00")
                    self.assertEqual(result.stdout.splitlines(), writes)

    def test_stopping_charging_never_cuts_adapter_power(self):
        expected_writes = {
            "native": ["native:off"],
            "tahoe": ["smc:CHTE:01000000"],
            "legacy": ["smc:CH0B:02", "smc:CH0C:02"],
        }
        for backend, writes in expected_writes.items():
            with self.subTest(backend=backend):
                result = self.run_control("disable_charging", TEST_BACKEND=backend)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), writes)

    def test_legacy_and_tahoe_enable_use_existing_smc_values(self):
        for backend, writes in {
            "legacy": ["smc:CH0B:00", "smc:CH0C:00"],
            "tahoe": ["smc:CHTE:00000000"],
        }.items():
            with self.subTest(backend=backend):
                result = self.run_control("set_charging_control on", TEST_BACKEND=backend)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), writes)

    def test_failed_legacy_write_is_not_masked_by_second_write(self):
        for command in ["on", "off"]:
            with self.subTest(command=command):
                result = self.run_control(
                    'set_charging_control "$TEST_COMMAND"',
                    TEST_BACKEND="legacy", TEST_COMMAND=command, SMC_FAIL_KEY="CH0B",
                )
                self.assertEqual(result.returncode, 23)
                self.assertEqual(len(result.stdout.splitlines()), 1)
                self.assertTrue(result.stdout.startswith("smc:CH0B:"))

    def test_unavailable_backend_rejects_control_without_writes(self):
        for command in ["set_charging_control on", "set_charging_control off", "apply_percentage_control 70 60 70"]:
            with self.subTest(command=command):
                result = self.run_control(command, TEST_BACKEND="unavailable")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_unknown_live_control_state_does_not_guess_a_write(self):
        result = self.run_control("apply_percentage_control 69 60 70", TEST_STATE="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_login_worker_waits_for_native_service_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "attempts"
            counter.write_text("0")
            executable = Path(directory) / "native"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            script = function("require_charging_control") + "\n" + function("wait_for_charging_service") + r'''
native_binary="$NATIVE_TEST_BINARY"
charging_backend=unavailable
smc_supports_tahoe=false
smc_supports_legacy=false
log() { :; }
sleep() { :; }
sudo() {
    [[ "$3" == status ]] || return 98
    local count=$(cat "$COUNT_FILE")
    count=$((count + 1))
    echo "$count" >"$COUNT_FILE"
    [[ "$count" -ge 3 ]] || return 1
    echo disabled
}
wait_for_charging_service && printf '%s:%s' "$charging_backend" "$native_status"
'''
            result = subprocess.run(
                ["/bin/bash", "-c", script], capture_output=True, text=True, timeout=2,
                env=dict(os.environ, COUNT_FILE=str(counter), NATIVE_TEST_BINARY=str(executable)),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "native:disabled")
            self.assertEqual(counter.read_text().strip(), "3")

    def test_adapter_on_restores_adapter_without_forcing_native_charging(self):
        command = r'''
battery_stub() { printf 'battery:%s:%s\n' "$1" "$2"; }
battery_binary=battery_stub
action=adapter
setting=on
''' + action_block("adapter")
        for backend in ["native", "unavailable", "legacy", "tahoe"]:
            with self.subTest(backend=backend):
                result = self.run_control(command, TEST_BACKEND=backend)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ["battery:maintain:stop", "smc:CHIE:00"])

    def test_discharge_completion_only_recovers_supported_maintenance(self):
        command = r'''
battery_stub() { printf 'battery:%s:%s\n' "$1" "$2"; }
battery_binary=battery_stub
action=discharge
setting=50
BATTERY_HELPER_MODE=0
''' + action_block("discharge")
        for backend in ["native", "unavailable"]:
            with self.subTest(backend=backend):
                result = self.run_control(command, TEST_BACKEND=backend, TEST_PERCENT=50)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = ["battery:maintain:stop", "smc:CHIE:08", "smc:CHIE:00"]
                if backend == "native":
                    expected.append("battery:maintain:recover")
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_native_maintenance_stop_releases_override_instead_of_enabling_it(self):
        command = r'''
assert_not_running_as_root() { :; }
stop_maintenance_workers() { printf 'workers:stop\n'; }
battery_stub() { printf 'battery:%s:%s\n' "$1" "$2"; }
battery_binary=battery_stub
native_binary=/usr/bin/true
smc_supports_tahoe=false
smc_supports_legacy=false
calibrate_pidfile=/dev/null/unused
action=maintain
setting=stop
''' + action_block("maintain")
        result = self.run_control(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "workers:stop", "battery:disable_daemon:", "smc:CHIE:00",
            "native:reset", "battery:status:",
        ])

    def test_adapter_on_reports_failed_restore_without_other_control_writes(self):
        command = r'''
battery_stub() { :; }
battery_binary=battery_stub
action=adapter
setting=on
''' + action_block("adapter")
        result = self.run_control(command, SMC_FAIL_KEY="CHIE")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ["smc:CHIE:00"])


if __name__ == "__main__":
    unittest.main()
