# MacScreen

> **Any Mac's screen, as if it were plugged into yours.**

[**Website**](https://danyk20.github.io/MacScreen/) ·
[**Download**](https://github.com/danyk20/MacScreen/releases/latest) ·
[Documentation](docs/USAGE.md) ·
[Report a problem](https://github.com/danyk20/MacScreen/issues/new?template=bug_report.yml)

The [project website](https://danyk20.github.io/MacScreen/) has the overview, a comparison with other tools,
install steps and the changelog.

MacScreen turns a second Mac into an external display for another Mac. The **Host** creates a
virtual display, captures it, encodes it with the hardware video encoder and streams it over the
network. The **Display** Mac decodes the stream and shows it full screen. Sound can optionally be
sent the same way through a virtual audio device.

**Private by design:** no registration, no email, no credit card, no subscription, and no data collected. See [Privacy](#privacy).

Goal: a display that feels cabled. Wi-Fi first, Thunderbolt or Ethernet second.

**Status:** beta (pre-release). Not notarized. Verified live on a 27-inch 5K iMac (Late 2015) as the Display and an
Apple Silicon Mac as the Host. See [Known limits](docs/USAGE.md#known-limits).

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

## Privacy

No registration. No email. No credit card. No subscription. Nothing collected.

MacScreen does not collect, store or share any data about you for analytics or any other purpose. There is no
telemetry, no analytics, no tracking, no account and no server run by this project. Your screen, audio and pairing
keys go directly between your two Macs, encrypted, and stay on those devices. Everything you configure is saved only
on your own Mac, and you can delete it at any time (see [docs/USAGE.md](docs/USAGE.md)).

The one internet request is an optional update check that fetches the public release list from GitHub (GitHub
sees the request like any web visit). You can turn it off in Settings, and the app then makes no internet requests.

## Documentation

- [docs/USAGE.md](docs/USAGE.md): requirements, build, permissions, pairing, launch flags, settings,
  audio driver, troubleshooting, security summary and known limits.
- [PLAN.md](PLAN.md): the design and task plan (protocol, architecture, milestones).
- [HANDOVER.md](HANDOVER.md): current working state.

## License

See [LICENSE](LICENSE).
