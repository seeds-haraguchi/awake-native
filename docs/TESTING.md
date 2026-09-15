# Awake safety test plan

These tests intentionally separate code-level tests from tests that alter the host Mac's global power settings.
Run the manual tests on a non-production Mac with no irreplaceable long-running work.

## Automated tests

```bash
xcodebuild \
  -project Awake.xcodeproj \
  -scheme Awake \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

The tests cover timer expiry, battery threshold behavior on battery and AC power, transient thermal pressure,
the three-minute thermal threshold, resetting the thermal window after recovery, and parsing the `pmset` sleep state.

## Before each privileged test

1. Build a properly signed app, copy it to `/Applications`, and approve its background item.
2. Keep Terminal open and record the baseline:

   ```bash
   pmset -g | grep SleepDisabled
   ```

3. If any test fails to restore the value to `0`, immediately run:

   ```bash
   sudo pmset -a disablesleep 0
   ```

## Normal operation

1. Turn Awake ON. Confirm the menu shows `Awake: ON` and `pmset -g` shows `SleepDisabled 1`.
2. Close the MacBook lid and verify a controlled remote task continues.
3. Reopen the lid, turn Awake OFF, and confirm `SleepDisabled 0` before testing normal sleep.

Repeat this test on both an Intel Mac and an Apple Silicon Mac. A Universal 2 build proves binary coverage,
but does not replace hardware behavior testing.

## Timer

Use a short custom timer. Turn Awake ON, wait for expiry, and confirm the menu reports the timer stop reason
and `SleepDisabled 0`.

## Battery safety

- On battery power, choose a threshold at or above the current charge, turn Awake ON, and confirm automatic stop.
- On AC power, repeat with the same threshold and confirm Awake remains ON.
- After both cases, explicitly confirm `SleepDisabled 0` after stopping.

## Thermal safety

The production threshold is deliberately fixed at three minutes. Unit tests exercise the state machine without
heating the machine. If an end-to-end thermal test is required, use an instrumented development build that injects
thermal observations; do not deliberately overheat hardware.

## Process-death recovery

1. Turn Awake ON and confirm `SleepDisabled 1`.
2. Find the app PID with `pgrep -x Awake`, then send `kill -9 <pid>`.
3. Poll `pmset -g`. XPC invalidation should restore immediately; the heartbeat deadline is a 45-second fallback.
4. Confirm `SleepDisabled 0` no later than 50 seconds after the kill.

## Helper-death recovery

1. Turn Awake ON and confirm `SleepDisabled 1`.
2. Locate the root helper in Activity Monitor and force quit it, or use an administrator shell to send it `SIGKILL`.
3. `launchd` should restart the helper. Its durable marker must cause startup restoration.
4. Confirm `SleepDisabled 0` and that the app no longer claims a confirmed OFF state until recovery completes.

## Reboot recovery

This is a destructive test for active work. Turn Awake ON, force-restart the test Mac, and confirm after boot that
the helper's `RunAtLoad` recovery cleared the durable marker and `pmset -g` reports `SleepDisabled 0`.

## Helper replacement on update

1. Install a released DMG, turn Awake ON once so the helper is registered, then turn it OFF and quit.
2. Install a DMG with a different build number over it without rebooting.
3. Launch Awake. The switch is disabled for up to about 20 seconds when the previous helper predates the version
   request, because that helper never replies.
4. Confirm with `log show --last 5m --predicate 'subsystem == "jp.co.seeds-std.Awake.Helper"'` that a helper
   reporting the new build started, then turn Awake ON and OFF and confirm `SleepDisabled` follows.
5. Repeat step 2 while the previous app left a durable marker (force quit the app while ON), and confirm launch
   recovery reports `SleepDisabled 0` before the helper is replaced and Awake can be turned ON.
