# MacScreen usage

This guide covers building, permissions, pairing, launch options, settings, the optional audio
driver, troubleshooting, the security design and the known limits.

Status markers used below:

- **Verified:** confirmed on hardware or by tests, as recorded in `HANDOVER.md`.
- **Not verified:** written from the code or plan but not tested end to end.

## Contents

- [Requirements](#requirements)
- [Build from source](#build-from-source)
- [Permissions](#permissions)
- [First run and pairing](#first-run-and-pairing)
- [Launch flags](#launch-flags)
- [Settings](#settings)
- [Audio driver (experimental)](#audio-driver-experimental)
- [Troubleshooting](#troubleshooting)
- [Security summary](#security-summary)
- [Known limits](#known-limits)

## Requirements

| Role | Requirement | Source |
| --- | --- | --- |
| Host | macOS 12.3 or later, private `CGVirtualDisplay` API present | `PLAN.md` §11, §1 |
| Host | Tested: Apple M2, macOS 27.0.1. Intel Host: **not verified** | `HANDOVER.md` |
| Display | macOS 12.0 or later | `Resources/Info.plist` (`LSMinimumSystemVersion`) |
| Display | Planned: iMac 27" 5K Late 2015 (Intel, macOS 12). **Not verified live** | `PLAN.md` §1, `HANDOVER.md` |
| Network | Local network. Wi-Fi: **not verified**. Ethernet or Thunderbolt Bridge: planned, not verified | `PLAN.md` §7 |

The Host needs hardware HEVC or H.264 encoding. The plan notes that the M2 can encode 4K at 60 fps
in real time but not 5K at 60 fps, so 4K60 is the highest 60 fps setting expected to work (native 5K at 30 fps is available as a manual choice)
(`HANDOVER.md`).

## Build from source

Requirements: Xcode command line tools with Swift 5.9 or later.

### Debug build and tests

```
swift build
swift test
```

`swift build` builds every target, including the `msprobe` command line tool. `swift test` runs the
unit and integration tests. The Host's virtual display tests skip when Screen Recording permission
is missing.

### App bundle

```
Scripts/make-app.sh
```

This builds a universal (`arm64` and `x86_64`) release build of `MacScreen` and `msprobe`, then
writes:

- `build/MacScreen.app`
- `build/msprobe`

The `build/` folder is git-ignored.

### Signing identity

`make-app.sh` picks a signing identity in this order:

1. `MACSCREEN_SIGN_ID`, if set in the environment.
2. `MacScreen Dev`, if it exists in the keychain.
3. Ad-hoc signing (`-`). The script prints a warning, because Screen Recording permission resets
   on every rebuild with ad-hoc signing.

Create the stable identity once:

```
Scripts/make-dev-cert.sh
```

This creates a self-signed code-signing certificate named `MacScreen Dev`, valid 10 years, and
imports it into the login keychain. Notes:

- The first `codesign` run may show a keychain prompt. Choose **Always Allow**.
- If `codesign` reports the identity as not trusted, open Keychain Access, double-click
  `MacScreen Dev`, expand **Trust** and set **Code Signing** to **Always Trust**.
- The certificate is self-signed. It is not an Apple Developer ID and does not make the app
  notarized.
- The script prints the same guidance when it finishes.

Status: `HANDOVER.md` records the dev certificate as installed on the Host. That Screen Recording
permission survives rebuilds with this identity is the documented intent (`make-dev-cert.sh`), not
yet checked in a log.

## Permissions

MacScreen asks for three permissions. macOS shows each prompt the first time the feature is used.

| Permission | Where | Why | Where to change it |
| --- | --- | --- | --- |
| **Screen Recording** | Host | The Host captures the virtual display. Without it there is no picture. | System Settings > Privacy & Security > Screen Recording |
| **Local Network** | Host and Display | Bonjour discovery of `_macscreen._tcp` and the connection to the other Mac. | System Settings > Privacy & Security > Local Network |
| **Microphone** | Host | Needed by macOS to read the audio device "MacScreen Display" for sound. The app does not use the microphone itself (`NSMicrophoneUsageDescription`). Only used when "Play sound on Display" is on. | System Settings > Privacy & Security > Microphone |

Notes:

- Screen Recording: after granting it, quit and reopen MacScreen (the app's own dialog says so).
- The Host checks Screen Recording with `CGPreflightScreenCaptureAccess()`. If it is missing, the
  Host menu shows **Screen Recording permission missing…**, which opens a dialog with the steps.
- The Microphone prompt for audio is described in `PLAN.md` §6.9 as "macOS asks once". Not verified
  on macOS 27.

## First run and pairing

### Choose a role

On first launch MacScreen asks for a role, stored in `UserDefaults` under `role`. Use the menu bar
item **MS**:

- **Mode → Host** (or **Use as Host** on first launch) on the Mac whose screen you want to extend.
- **Mode → Display** (or **Use as Display** on first launch) on the Mac that will show the extra screen.

To change the role later, relaunch with `--role host` or `--role display` (see
[Launch flags](#launch-flags)), or use the same menu items.

### Pair the two Macs (once)

Pairing is needed the first time the Host and Display meet, and again if either side forgets the
other's key. Steps as described in `PLAN.md` §6.5:

1. On the **Display**, open the **MS** menu and choose **Show Pairing Code**. A 6-digit code is
   shown full screen.
2. On the **Host**, open the **MS** menu, choose **Connect to <Display name>**, and type the 6-digit
   code into the prompt, then click **Pair**.
3. The Host compares the typed code with its own value. If they match, the Display asks
   **Allow <Host name>?**. Click **Allow** (or press Return) on the Display.

Both Macs store the other's identity key in
`~/Library/Application Support/MacScreen/identity.json` (file mode 0600).

After pairing, later connections need no code. Step 3 needs the iMac's mouse or keyboard once.
The Display has no input from the Host (`PLAN.md` §11).

Status: the pairing protocol is specified in `PLAN.md` §6.5. The loopback test (Host and Display on
the same Mac, Display in windowed mode) was confirmed working on 2026-11-17 (`HANDOVER.md`).
The on-screen pairing flow between two physical Macs is **not verified**.

### Connect and use

1. On the Host, choose **Connect to <Display name>** from the **MS** menu. The Display's window
   goes full screen while connected.
2. Use **Mirror Main Display** in the Host menu to mirror instead of extend (`PLAN.md` §7).
3. Use **Play Sound on Display** to route system audio to the Display (experimental; see
   [Audio driver](#audio-driver-experimental)).
4. Use **Testing → Run Setup Test** on the Host to measure the link and encoder for a Display (the probe
   described in `PLAN.md` §6.10 and `Sources/MSProbe`). Not verified end to end on the Display.
5. Disconnect with **Disconnect from <Display name>**.

#### Connect by address (when the Display is not listed)

Discovery uses Bonjour, which guest Wi-Fi, some routers and VPNs block. Then:

1. On the Display, choose **Show Address…** in the MacScreen menu. It lists this Mac's IP address(es).
2. On the Host, choose **Connect to Address…** and type the address, for example `192.168.1.20`. A
   `:port` suffix is only needed if the Display says so (the default port is 47800; if it is taken the
   Display uses another one and shows it). Pairing works exactly as with a discovered Display.

Both Macs must still be able to reach each other on the network (same subnet, or a routed path).

#### Rename a Mac

**Settings… → This Mac → Name**. The Display's name is what the Host lists; the Host's name appears in
the pairing dialogs. Leave the field empty to use the Mac's own name. A Display re-advertises under the
new name immediately; a Host uses it from its next connection.

#### Updates

Choose **Check for Updates…** in the menu. If a newer release exists, **Install and Restart** downloads
it from GitHub, verifies its SHA-256 checksum against the release's `SHA256SUMS.txt`, replaces the app and
reopens it. The app also checks about once a day (turn this off in Settings → General). Because the app is
not signed by Apple, macOS may ask the Host to allow Screen Recording again after an update.
Installing in place needs MacScreen to be in a folder you can write to (normally Applications); otherwise the
new disk image is opened and you drag the app over the old one. Pre-release builds follow pre-releases and
stable releases; stable builds follow stable releases only.

Lifecycle, as specified (`PLAN.md` §7):

- If the Display disconnects or the control connection times out, the Host removes the virtual
  display and restores the previous audio output.
- The Host reconnects automatically when the Display is seen again. macOS restores the display
  arrangement because the virtual display keeps the same serial.
- Host sleep sends `bye` and tears the session down. Wake reconnects.

These lifecycle rules are **not verified** end to end.

## Launch flags

Flags are read in `Sources/MacScreen/Role.swift`. Run the binary directly to pass flags:

```
build/MacScreen.app/Contents/MacOS/MacScreen --role display --windowed --stats
```

| Flag | Effect |
| --- | --- |
| `--role host` or `--role display` | Sets the role and stores it in `UserDefaults` (`role`). An invalid value is logged and ignored. Without the flag the stored role is used. |
| `--windowed` | Display renders into a 960×540 window instead of full screen. Used for testing on one Mac. |
| `--stats` | Shows the statistics overlay. Its contents are not listed in this guide. |
| `--connect <name>` | Host only. Connects automatically to the first Display whose name contains `<name>`. Case-insensitive substring match. Also accepts `--connect=<name>`. |
| `--cursor embedded` or `--cursor overlay` | Cursor mode. `embedded` (default) draws the cursor in the video. `overlay` sends the cursor separately for lower latency. Any other value is treated as `embedded`. Also accepts `--cursor=<mode>`. |
| `--latency-csv <file>` | Display writes its per-frame latency log to `<file>` when it quits. Also accepts `--latency-csv=<file>`. |

Example, Host connecting automatically:

```
build/MacScreen.app/Contents/MacOS/MacScreen --role host --stats --connect iMac
```

The single-Mac loopback test used in `HANDOVER.md`:

```
build/MacScreen.app/Contents/MacOS/MacScreen --role display --windowed --stats
build/MacScreen.app/Contents/MacOS/MacScreen --role host --stats
```

Then, in the Host's **MS** menu, choose **Connect**, type the code and click **Allow** on the
Display.

## Settings

Open the **MS** menu and choose **Settings…** (shortcut ⌘,). The Settings window has these options,
from `Sources/MacScreen/SettingsWindow.swift`:

| Section | Option | Values |
| --- | --- | --- |
| Video | Resolution | Maximum height: options 2160, 1440, 1080, 720, and a value of 0 (the label for 0 is not checked here) |
| Video | Frame rate | 30 or 60 fps |
| Video | Codec | HEVC or H.264 |
| Video | Bitrate cap | Automatic, or a fixed cap in Mbit/s |
| Video | HDR | Disabled. Shows "HDR is not supported yet." |
| Cursor | Cursor mode | Embedded in video, or Overlay (lower latency) |
| General | Show stats overlay | On or off |
| General | Check for updates automatically | On (default) or off |
| General | Launch at login | On or off |
| This Mac | Name | How this Mac appears to the other Mac; empty = the Mac's own name |

The note in the window says that changes apply to the next connection, and values are limited to
what the Display supports. The Display's `launch at login` uses
`~/Library/LaunchAgents/app.macscreen.display.plist` (`PLAN.md` §7).

## Audio driver (experimental)

Sound is sent through a virtual audio device, "MacScreen Display". The driver is a C AudioServer
plug-in. It is **experimental and not verified on macOS 27**. Gate G4 in `PLAN.md` §9 (does the
driver load when signed ad-hoc or with the dev certificate on macOS 27) is still open.

### Build

```
Scripts/build-audio-driver.sh
```

This runs the ring buffer test, builds a universal `build/MacScreenAudio.driver`, and signs it with
the same identity rules as the app.

### Install (needs administrator password)

```
Scripts/install-audio-driver.sh
```

The script shows what it will do and asks `Continue? [y/N]`. Then it:

1. Removes any existing `/Library/Audio/Plug-Ins/HAL/MacScreenAudio.driver` (with `sudo`).
2. Copies the new driver there (with `sudo`) and sets owner `root:wheel`.
3. Runs `sudo killall coreaudiod`. All system audio stops for a moment.

The device "MacScreen Display" should appear in Sound settings within a few seconds.

### Uninstall

```
Scripts/uninstall-audio-driver.sh
```

This removes the driver (with `sudo`) and restarts `coreaudiod`, after the same confirmation.

### Using it

Host menu: **Play Sound on Display**. The app sets the system default output to the device and
remembers the previous output. On disconnect it restores that output if the device is still the
default (`PLAN.md` §6.9).

Sound is sent as 48 kHz, 2-channel audio, and the Display buffers about 25 ms. The audio delay
target is within 60 ms of video (`PLAN.md` §8, T5.3). **Not verified.**

## Troubleshooting

### The MS menu bar item is not visible

- The menu bar is full. macOS hides status items when there is no room, and on a notched MacBook
  the item can sit behind the notch. Quit other menu bar apps, or remove some items, to make room.
- The app is in full screen. The menu bar is hidden in full screen. Move the pointer to the top of
  the screen, or leave full screen.
- MacScreen has no Dock icon (`LSUIElement`). If you cannot reach the item, quit the app from
  Activity Monitor, or run `killall MacScreen` in Terminal, then start it again with the same
  command-line flags.

These causes are standard macOS behaviour and were reported by the user. They are not specific to
MacScreen code, and no fix in the app itself is in the repo.

### No picture on the Display, and the Host says Screen Recording is missing

The Host needs Screen Recording permission to capture the virtual display. Without it there is no
picture.

1. Open the Host's **MS** menu. If it shows **Screen Recording permission missing…**, click it.
2. In System Settings > Privacy & Security > Screen Recording, enable MacScreen.
3. Quit MacScreen and start it again.

If permission was granted but resets after every rebuild, the app was signed ad-hoc. Create the
stable identity with `Scripts/make-dev-cert.sh`, then rebuild with `Scripts/make-app.sh`, and grant
permission once more.

### The Display is asleep or locked, and the Host shows no display

Reported behaviour: with the Display asleep or its screen locked, the Host's capture finds no
display, so the session does not produce a picture. The app sends `hostState` messages so the
Display knows when the Host's display is asleep. **Recovery after an idle or locked screen is not
verified** (`HANDOVER.md`: "idle-screen recovery untested"). If the picture does not return, use
**Disconnect** and **Connect** again on the Host.

### Connect fails or the code is rejected

- Check that both Macs are on the same local network and that Local Network permission is granted
  on both.
- Check that the code is the one currently shown on the Display. A new code can be shown with
  **Show Pairing Code** on the Display.
- If the Display is not listed at all, use **Connect to Address…** (see [Connect by address](#connect-by-address-when-the-display-is-not-listed)).
- If the Display forgot the Host, pairing runs again (see [Pair the two Macs](#pair-the-two-macs-once)).

### Sound does not appear on the Display

- Check that `build/MacScreenAudio.driver` was installed (see [Audio driver](#audio-driver-experimental)).
- Check System Settings > Sound for the "MacScreen Display" device.
- Check that the Host has Microphone permission, because the Host reads the device as an input.

## Security summary

This summarises the design in `PLAN.md` §6.5 and §6.6. The code is in `Sources/MSProtocol`. It has
**not had an independent security review**.

- **Key exchange and identity:** each side has an Ed25519 identity key and creates a fresh X25519
  key per session. The Host commits to its ephemeral key and nonce first (commit = SHA256 of both)
  and reveals them later. This stops the Host choosing its key after seeing the Display's.
- **Transcript signatures:** both sides sign the SHA256 transcript of both identity keys, both
  ephemeral keys and both nonces with Ed25519. This binds the session to the two identities.
- **Key derivation:** HKDF-SHA256 over the X25519 shared secret, with the transcript as salt and
  a separate label for each direction (`ctl-h2d`, `ctl-d2h`, `med-h2d`, `med-d2h`).
- **Encryption:** after the handshake, control messages are sealed with ChaCha20-Poly1305. The
  nonce is 4 zero bytes plus a 64-bit message counter per direction, so it is not sent on the wire.
  Media packets also use AEAD (`PacketCipher.swift`), with a replay window (`ReplayWindow.swift`).
- **Pairing check:** when a side does not know the other's identity key, a 6-digit code is derived
  from the transcript (first four bytes of SHA256("SAS" ‖ transcript), modulo 1,000,000). The
  Display shows it, the user types it on the Host, and the Host compares. A match stores the keys
  on both sides.
- **Key storage:** identity keys and paired peers are in
  `~/Library/Application Support/MacScreen/identity.json`, file mode 0600.

Limits of this design:

- The pairing code has about 20 bits of entropy. Its only purpose is a human check during pairing,
  so do not pair on an untrusted network without comparing the code on both screens.
- Pairing needs physical access to the Display for the Allow step.
- The app has no input from the Display and no remote control of the Host.
- The virtual display uses a private API, so macOS changes may affect behaviour.

## Known limits

- **Private API:** the virtual display uses `CGVirtualDisplay`, which is not public. It may stop
  working in a macOS update. The code is built against the macOS 27 SDK with a 12.0 deployment
  target (`PLAN.md` §1).
- **Not notarized:** the app is signed ad-hoc, so macOS Gatekeeper warns on first launch (right-click, Open) and the
  Host may be asked to allow Screen Recording again after an update. Notarization needs a paid Apple Developer
  account and is on the roadmap. Installing with Homebrew clears the first-launch warning.
- **No HDR or 10-bit:** the HDR toggle in Settings is disabled. HDR was dropped for v1, and 10-bit output was tested
  and set aside because the 2015 iMac decodes 10-bit HEVC in software (`docs/hdr-spike.md`).
- **Wi-Fi measured on one setup:** streaming over Wi-Fi works (about 50-60 fps and a median of roughly 55-60 ms
  capture-to-present on a 2015 5K iMac in our tests). Results depend on the router. Wired links (Ethernet,
  Thunderbolt Bridge) are supported but their numbers have not been measured yet.
- **One Display model verified live:** the 27-inch 5K iMac (Late 2015, macOS 12.7). Other Display Macs are expected to
  work but are untested.
- **Encoder limit:** 5K at 60 fps cannot be encoded in real time on the M2 we tested; native 5K runs at 30 fps (manual
  choice in Settings). Faster Macs may manage 5K at 60 fps (Settings → Resolution: native, Frame rate: 60), but that is
  untested and also needs a fast network. 4K at 60 fps is the
  realistic top 60 fps setting (`HANDOVER.md`). No H.264 candidates above 4096×2304.
- **One Display at a time** and **no input from the Display** (`PLAN.md` §11).
- **Audio is experimental:** the driver works on macOS 27 with good quality and sync in our testing, but needs a manual
  install (administrator password) and has had little long-run testing.
- **Host macOS older than 12.3** is out of scope (`PLAN.md` §11).
