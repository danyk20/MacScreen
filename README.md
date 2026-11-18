# MacScreen

MacScreen turns a second Mac into an external display for another Mac. The **Host** creates a
virtual display, captures it, encodes it with the hardware video encoder and streams it over the
network. The **Display** Mac decodes the stream and shows it full screen. Sound can optionally be
sent the same way through a virtual audio device.

Goal: a display that feels cabled. Wi-Fi first, Thunderbolt or Ethernet second.

**Status:** early development, version 0.1.0. Not notarized. Not yet verified end to end on the
intended Display hardware. See [Known limits](docs/USAGE.md#known-limits).

## Install

**Homebrew** (installs the app and opens it without a Gatekeeper warning):

```
brew tap danyk20/macscreen https://github.com/danyk20/MacScreen
brew install --cask macscreen
```

**Or download** the `.dmg` from the [latest release](https://github.com/danyk20/MacScreen/releases/latest), open it and
drag MacScreen to Applications. The app is not notarized by Apple, so the first time right-click it and choose
**Open**. Do this on both Macs, then see [docs/USAGE.md](docs/USAGE.md) for pairing.

## Requirements

- **Host:** macOS 12.3 or later (`PLAN.md` §11). Built and tested only on
  an Apple M2 Mac running macOS 27. The virtual display uses the private `CGVirtualDisplay` API.
- **Display:** macOS 12.0 or later (`LSMinimumSystemVersion` in `Resources/Info.plist`). The first
  planned Display is an iMac 27" 5K (Late 2015, Intel); this is not yet verified live.
- Both Macs on the same local network.
- Xcode command line tools with Swift 5.9 or later (`Package.swift`, tools version 5.9).

## Build

```
swift build          # debug build of all targets, native architecture
swift test           # unit and integration tests
```

To build the app bundle (universal arm64 and x86_64, release):

```
Scripts/make-dev-cert.sh   # once: creates the self-signed "MacScreen Dev" signing identity
Scripts/make-app.sh        # writes build/MacScreen.app and build/msprobe
Scripts/deploy-display.sh user@imac.local   # optional: copy the app to the iMac (needs Remote Login)
Scripts/test.sh            # build and run the tests (--with-display-tests adds the screen-flickering ones)
```

Details, signing identity behaviour and the audio driver are in [docs/USAGE.md](docs/USAGE.md).

## Quick start

1. Build and install as above, then open `build/MacScreen.app` on both Macs.
2. On the Host, grant Screen Recording permission (the menu shows a warning until it is granted).
3. On the Host, choose **Connect to <Display name>**, type the 6-digit code shown on the Display,
   then click **Allow** on the Display.

Full instructions, launch flags and troubleshooting: [docs/USAGE.md](docs/USAGE.md).

## Documentation

- [docs/USAGE.md](docs/USAGE.md): requirements, build, permissions, pairing, launch flags, settings,
  audio driver, troubleshooting, security summary and known limits.
- [PLAN.md](PLAN.md): the design and task plan (protocol, architecture, milestones).
- [HANDOVER.md](HANDOVER.md): current working state.

## License

See [LICENSE](LICENSE).
