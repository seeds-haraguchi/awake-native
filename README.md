# Awake

**Keep your Mac awake, even with the lid closed.**

Awake is a native macOS menu-bar utility for keeping long-running work alive: SSH and remote sessions,
downloads, builds, backups, data processing, and any other task that should continue while a MacBook lid is closed.
It is implemented entirely in Swift and uses native macOS frameworks.

## Safety model

Awake treats restoration as more important than sleep prevention. For power state managed by Awake, the menu does
not report a confirmed OFF state until the privileged helper confirms `/usr/bin/pmset -a disablesleep 0`. A
pre-existing unowned `SleepDisabled 1` state is shown as an explicit warning instead of being silently overwritten.

- The app process owns the IOKit idle-sleep assertion. macOS releases it automatically if the app dies.
- A minimal root LaunchDaemon owns only the `pmset` change and recovery lease.
- The helper writes a root-only durable marker before enabling `disablesleep`.
- An XPC disconnect restores immediately. A 45-second heartbeat expiry is the independent fallback.
- `launchd` restarts a killed helper; startup detects the marker and restores before accepting work.
- Failed restoration keeps the marker and retries every five seconds.
- XPC peers are restricted by bundle identifier and matching signing Team ID. No arbitrary command, path, or argument
  can cross the privileged boundary.

The helper is installed from inside the app bundle with `SMAppService`. Awake never opens a Terminal-style `sudo`
password prompt. macOS presents its native Background Items approval flow when the helper is first registered.

## Features

- Menu-bar-only SwiftUI app (`MenuBarExtra`), with no normal Dock icon
- Awake ON/OFF with clear status
- Timer: Off, 1, 2, 4, or 8 hours, plus a custom duration
- Battery Safety: Off, 10%, 20%, or 30%; ignored while on AC power
- Thermal Safety: automatic stop after `serious` or `critical` persists for three minutes
- Live battery, power-source, thermal, and remaining-time status
- Universal 2 app and helper (`x86_64` + `arm64`)
- Hardened Runtime-ready Developer ID distribution and notarization script

## Architecture

```text
Awake.app (logged-in user)
  SwiftUI menu bar and state machine
  IOKit idle-sleep assertion
  IOKit battery and AC status
  ProcessInfo thermal state
  timer and safety policy
             |
             | authenticated NSXPCConnection
             v
AwakeHelper (root, SMAppService LaunchDaemon)
  fixed enable / heartbeat / restore API only
  durable root-only lease marker
  /usr/bin/pmset -a disablesleep 1 or 0
  XPC-disconnect and heartbeat deadman recovery
```

## Source layout

```text
Awake.xcodeproj/
macOS/
  AwakeApp/       SwiftUI app, lifecycle, XPC client
  AwakeCore/      assertion, monitoring, safety policy
  AwakeHelper/    root daemon, pmset adapter, durable lease
  AwakeShared/    constants and the narrow XPC protocol
  AwakeTests/     deterministic safety-policy tests
docs/TESTING.md   privileged and hardware test procedure
scripts/          Universal build and notarized DMG workflows
```

## Requirements

- macOS 13 Ventura or later
- Xcode 16 or later
- A code-signing team for helper registration
- Apple Developer Program membership, Developer ID certificates, and notarization credentials for public release

The deployment target is macOS 13 because both `MenuBarExtra` and the modern `SMAppService` LaunchDaemon API begin
there. Supporting older systems would require a separate UI path and the deprecated helper-installation model.

The app is intentionally not App Sandbox-enabled. It uses the Hardened Runtime and exposes no general-purpose root
API. The current distribution target is Developer ID outside the Mac App Store.

## Configure identifiers before signing

The checked-in project uses the explicit placeholder prefix `com.example.Awake`. Before a signed development build
or release, replace every `com.example.Awake` occurrence with a reverse-DNS identifier owned by your organization.
The app ID, helper ID, Mach service, LaunchDaemon label, marker path, XPC signing requirements, and project build
settings must stay aligned.

Verify that no placeholder remains:

```bash
rg 'com\.example\.Awake'
```

Then select the same Apple Development Team for both the `Awake` and `AwakeHelper` targets in Xcode.

## Build

Open `Awake.xcodeproj`, select the same Apple Development Team for the `Awake` and `AwakeHelper` targets, and build.
For a signed Universal 2 development artifact that can register the privileged helper:

```bash
DEVELOPMENT_TEAM='YOUR_TEAM_ID' ./scripts/build-development.sh
```

This creates `build/Awake.app`. Copy it to `/Applications` before turning Awake ON. An Apple-issued signing
certificate for that Team ID must be installed in the login keychain.

For a compile-only unsigned Universal 2 artifact:

```bash
./scripts/build-universal.sh
```

This creates `build/Awake-unsigned.app` and verifies both embedded executables contain `x86_64` and `arm64` slices.
The unsigned build can be inspected but cannot register the privileged helper and must not be used for functional
Awake ON/OFF testing.

For local helper testing, use a signed build in `/Applications`. The first attempt to turn Awake ON registers the
LaunchDaemon. Approve Awake in **System Settings > General > Login Items & Extensions**, then turn it on again.

## Test

```bash
xcodebuild \
  -project Awake.xcodeproj \
  -scheme Awake \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

The full privileged, process-death, reboot, lid-close, Intel, and Apple Silicon procedures are in
[`docs/TESTING.md`](docs/TESTING.md). These host-level checks are not run automatically because they intentionally
alter global power behavior or terminate processes.

## Developer ID, notarization, and DMG

Store notarization credentials once, without placing secrets in the repository:

```bash
xcrun notarytool store-credentials AwakeNotary \
  --apple-id 'YOUR_APPLE_ID' \
  --team-id 'YOUR_TEAM_ID' \
  --password 'APP_SPECIFIC_PASSWORD'
```

After replacing the placeholder identifiers, run:

```bash
DEVELOPMENT_TEAM='YOUR_TEAM_ID' \
NOTARY_PROFILE='AwakeNotary' \
./scripts/release-notarized-dmg.sh
```

The script archives a signed Universal 2 app, verifies nested signatures and architectures, notarizes and staples
the app, creates and signs a DMG, then notarizes, staples, and Gatekeeper-checks that DMG. The output is
`build/distribution/Awake.dmg`.

## Operational notes

- Install the signed app in `/Applications`; Apple recommends this for an `SMAppService` daemon that must be
  available during boot.
- `pmset disablesleep` changes a system-wide setting and requires root. Only the embedded helper performs it.
- Battery and thermal safety run in the user app. Killing the app still triggers root-side restoration.
- The idle assertion prevents user-idle system sleep. Lid-close behavior additionally requires the privileged
  `pmset disablesleep` setting.
- `disablesleep` is not described in Apple's public `pmset` man page. Validate every supported macOS/hardware release
  using the manual matrix before shipping.
- Before deleting the app, turn Awake OFF, confirm `pmset -g` shows `SleepDisabled 0`, and quit Awake.

## References

- [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/)
- [Apple: Getting Started with SMAppService](https://developer.apple.com/forums/thread/802443)
- [Apple: Validating the signature of an XPC process](https://developer.apple.com/forums/thread/681053)
- [Original tanabee/awake](https://github.com/tanabee/awake)
