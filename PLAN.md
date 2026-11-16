# MacScreen — detailed implementation plan

## 1. Context

Goal: use a second Mac as a real external display for a newer Mac, over Wi-Fi first and
Thunderbolt/Ethernet second, smooth enough to feel cabled. First target Display is an
iMac 27" 5K Late 2015 (Intel Skylake i5, macOS 12, display-only, no input). The Host is
this Mac (Apple M2, macOS 27.0.1, Xcode 27.2, Swift 6.4.2).

The repo `/Users/danielkosc/Documents/Projects/MacScreen` is empty except a high-level
`PLAN.md`. This document replaces it (task T0.1 copies it into the repo as `PLAN.md`).

Verified on this Mac while planning:
- The macOS 27.2 SDK accepts deployment target **12.0** and builds **x86_64 + arm64**.
- The private classes `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`,
  `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` exist on macOS 27.
- Hardware HEVC and H.264 encoders are present on the Host.

Not verified (settled by measurement, see Gates in §9): what the iMac can decode,
HiDPI/HDR behaviour of the virtual display on macOS 27, Wi-Fi latency, loading of an
ad-hoc signed audio driver.

## 2. Who does what (model rule from the user)

- **Implementation:** every coding task is run by a subagent with
  `Agent(model: "sonnet", effort: "medium")` (Sonnet 5.5, medium effort). One task = one
  subagent run. The task text in §8 is the brief; the subagent also reads §3–§7.
- **Decisions and debugging:** done by the main session (Fable 5.2) only. Sonnet never
  changes a design decision, a constant in §5–§6, or the wire format. If a task cannot be
  done as written, the subagent stops and reports; Fable decides.
- **After every task Fable:** reads the diff, runs the task's acceptance commands itself,
  fixes or re-briefs, then commits (`git commit`, one commit per task, message
  `T<id>: <title>`). Approving this plan authorises those local commits. No push.
- **The user:** runs things on the iMac (or enables SSH, see T0.4), grants permissions,
  and confirms what is seen on screen at each milestone.

## 3. Rules for implementers (read before any task)

1. Swift, language mode 5 (`swiftLanguageModes: [.v5]`), deployment target macOS 12.0,
   universal binary. No third-party dependencies at all.
2. Any API newer than macOS 12.0 must be inside `if #available(macOS X, *)` with a
   working fallback or a clearly reported "unsupported" state. `MSHost` capture code is
   `@available(macOS 12.3, *)`.
3. All integers on the wire are **big-endian**. Use only `ByteWriter`/`ByteReader`
   (T0.2) to build and parse packets. Never use `withUnsafeBytes` casts of structs.
4. Never block or do heavy work on the main thread. Use the named serial queues in §4.3.
   Never call `DispatchQueue.main.sync`.
5. Hot path (per frame / per packet): no `print`, no JSON, no `Data` copies that can be
   avoided, no locks held across calls into VideoToolbox or Network.framework.
6. No force unwrap (`!`), no `try!`, no `fatalError` outside tests. Every failure becomes
   a typed `Error` and a log line.
7. Logging: `os.Logger(subsystem: "app.macscreen", category: "<module>")` only.
8. Every constant comes from `MSCore/Constants.swift`. Do not invent new numbers.
9. Each task ships its unit tests. A task is not done until `swift build` and
   `swift test` pass with zero warnings in the files it touched.
10. Do not touch files outside the task's "Files" list, except adding a target to
    `Package.swift` when the task says so.
11. Every `CVPixelBuffer`, `CMSampleBuffer` and Metal texture is IOSurface-backed and
    passed by reference. Never copy pixel data on the CPU.

Common mistakes to avoid:
- Creating a `CGVirtualDisplay` and letting it deallocate (the display vanishes). The
  owner object must hold it strongly for the whole session.
- Feeding the decoder a frame after a lost frame. After any unrecoverable loss, drop
  everything until the next keyframe (§6.6).
- Reusing an AEAD nonce. One counter per direction per key, never reset within a session.
- Drawing the cursor twice (capture must set `showsCursor = false` in overlay mode).
- Calling `nextDrawable()` on the main thread.

## 4. Architecture

### 4.1 Processes and roles
One app, `MacScreen.app`, bundle id `app.macscreen.MacScreen`, `LSUIElement = true`.
Role is stored in `UserDefaults` key `role` (`host` | `display`), asked on first launch,
overridable with `--role host|display`. Extra flags: `--windowed` (Display renders in a
960×540 window, used for single-Mac testing), `--stats` (overlay on).

### 4.2 Data flow
```
HOST                                                        DISPLAY
VirtualDisplay ► ScreenCapturer ► VideoEncoder ► Fragmenter+FEC ┐
CursorTracker ──────────────────────────────────────────────────┼► MediaChannel (UDP, AEAD) ► Reassembler ► VideoDecoder ► MetalRenderer
AudioCapture (loopback driver) ─────────────────────────────────┘                          ► CursorLayer / AudioPlayer
                  ControlChannel (TCP, framed, AEAD after handshake) both ways
                  Feedback / NACK / pong: DISPLAY ► HOST over the same UDP flow
```

### 4.3 Queues (all serial, QoS `.userInteractive` unless noted)
| Queue label | Owner | Work |
|---|---|---|
| `ms.capture` | Host | ScreenCaptureKit output callback, calls encoder |
| `ms.encode.out` | Host | encoder output: fragment, FEC, encrypt, send |
| `ms.media` | both | UDP receive, decrypt, dispatch by packet type |
| `ms.decode` | Display | reassembly completion, decoder submit |
| `ms.render` | Display | Metal draw, latest-frame-wins |
| `ms.control` (`.userInitiated`) | both | control channel I/O and session state machine |
| `ms.audio` | both | audio packets (real-time callbacks touch only the ring buffer) |
| main | both | UI, cursor layer updates, virtual display create/destroy |

### 4.4 Package layout
```
Package.swift                      swift-tools-version 5.9, platforms [.macOS(.v12)]
Sources/
  CPrivateAPI/                     ObjC target: include/CPrivateAPI.h (declarations only), shim.m (empty)
  MSCore/                          Constants, Log, MonoClock, ByteWriter/Reader, SPSCRingBuffer, Stats
  MSProtocol/                      ControlMessage, PacketHeader, payload codecs, ReedSolomon,
                                   Fragmenter, Reassembler, Handshake, PacketCipher, ReplayWindow
  MSTransport/                     Discovery, ControlChannel, MediaChannel, PingClock
  MSCodec/                         CodecCapabilities, ParameterSets, VideoEncoder, VideoDecoder
  MSHost/                          VirtualDisplay, ScreenCapturer, CursorTracker, PacketHistory,
                                   RateController, AudioCapture, HostSession
  MSDisplay/                       MetalRenderer, DisplayWindow, CursorLayer, AudioPlayer, DisplaySession
  MSProbe/                         TestPattern, SampleFile, EncodeBench, DecodeBench, LinkProbe,
                                   ProfileRecommender
  MSProbeCLI/                      CLI target; product (binary) name is `msprobe`
  MacScreen/                       App: AppDelegate, RoleChooser, HostMenu, DisplayController,
                                   PairingUI, SettingsWindow, LoginItem, IdentityStore, Permissions
AudioDriver/                       MacScreenAudio.c, Info.plist
Scripts/                           make-dev-cert.sh, make-app.sh, deploy-display.sh,
                                   build-audio-driver.sh, install-audio-driver.sh, uninstall-audio-driver.sh
Resources/Info.plist
Tests/                             MSCoreTests, MSProtocolTests, MSCodecTests, MSProbeTests, MSTransportTests
```
Dependencies only go downward: `MSCore` ← `MSProtocol` ← `MSTransport`; `MSCodec` ← `MSCore`;
`MSHost`, `MSDisplay`, `MSProbe` ← all of those; `MacScreen`, `msprobe` ← everything.

The app bundle is assembled by `Scripts/make-app.sh` (no Xcode project): universal
release build, copy binary and `Info.plist` into `build/MacScreen.app`, sign.
Metal shaders are a Swift string compiled at runtime with `device.makeLibrary(source:)`.

### 4.5 Signing without a paid account
`make-dev-cert.sh` creates a self-signed code-signing certificate "MacScreen Dev" in the
login keychain once. `make-app.sh` signs with `$MACSCREEN_SIGN_ID`, else "MacScreen Dev",
else ad-hoc (`-`) with a printed warning that Screen Recording permission will reset on
every rebuild. A stable identity keeps the permission across rebuilds.

## 5. Constants (`MSCore/Constants.swift`)

| Name | Value |
|---|---|
| `protoVersion` | 1 |
| `bonjourType` | `_macscreen._tcp` |
| `fragmentSize` | 1200 bytes |
| `maxDataFragsPerBlock` | 64 |
| `maxParityFragsPerBlock` | 32 |
| `fecRatioWiFi` / `fecRatioWired` | 0.10 / 0.0 (adaptive range 0…0.30) |
| `packetHistoryMs` | 500 |
| `nackMaxRttMs` | 8 (NACK used only when RTT is below this) |
| `reassemblyMaxFrames` | 8 |
| `keyframeMinIntervalMs` | 250 |
| `feedbackIntervalMs` | 100 |
| `pingIntervalMs` | 250 |
| `controlKeepaliveS` / `controlTimeoutS` | 1 / 5 |
| `cursorPollHz` / `cursorShapePollHz` | 120 / 20 |
| `audioSampleRate` / channels / frames per packet | 48000 / 2 / 240 (5 ms, s16le) |
| `audioTargetBufferMs` | 25 |
| `bitsPerPixelHEVC` / `bitsPerPixelH264` | 0.06 / 0.09 (per pixel per frame) |
| `minBitrate` | 3 000 000 bit/s |
| `linkBudgetShare` | 0.6 of measured throughput |
| `vendorID` / `productID` | 0x4D53 / 0x0001 |

## 6. Specifications

### 6.1 Private API header (`CPrivateAPI.h`)
Declarations only; symbols come from CoreGraphics at link time.
```objc
@class CGVirtualDisplay;
@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) NSUInteger width, height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(retain, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end
```
If any selector is missing at runtime (`responds(to:)` check), `VirtualDisplay.create`
throws `.privateAPIUnavailable`; the app shows a clear message instead of crashing.

### 6.2 Virtual display (`MSHost/VirtualDisplay.swift`)
```swift
struct VirtualDisplayConfig { var name: String; var pixelWidth: Int; var pixelHeight: Int
  var hiDPI: Bool; var refreshRate: Double; var sizeMM: CGSize; var serial: UInt32 }
final class VirtualDisplay {                       // main thread only
  static func create(_ c: VirtualDisplayConfig) throws -> VirtualDisplay
  var displayID: CGDirectDisplayID { get }
  func apply(_ c: VirtualDisplayConfig) throws     // change mode without destroying
  func setMirrorsMain(_ on: Bool) throws           // CGConfigureDisplayMirrorOfDisplay, .forSession
  func destroy()
}
```
- `maxPixelsWide/High` = pixel size. HiDPI: `hiDPI = 1`, mode = (pixel/2, 60 Hz).
  Non-HiDPI: `hiDPI = 0`, mode = (pixel, 60 Hz).
- `serial` = first 4 bytes of SHA-256 of the Display's `deviceId`, so macOS remembers
  arrangement per Display. `sizeMM` comes from the Display's `capabilities`.
- sRGB primaries in v1 (R .64,.33  G .30,.60  B .15,.06  W .3127,.3290); P3 in M6.

### 6.3 Capture (`MSHost/ScreenCapturer.swift`)
`SCStream` with `SCContentFilter(display:excludingWindows: [])`. Find the `SCDisplay`
whose `displayID` matches; retry `SCShareableContent.current` every 200 ms for up to 3 s
after display creation. Configuration:
`width/height` = pixel size · `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
· `colorSpaceName = CGColorSpace.sRGB` · `colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2`
· `minimumFrameInterval = CMTime(1, fps)` · `queueDepth = 3` · `showsCursor = false`
(true in "embedded cursor" mode) · `scalesToFit = false`.
In the output callback: read `SCStreamFrameInfo.status`; forward only `.complete` frames.
Idle screens produce no frames; that is intended. If the encoder still has a frame in
flight (`pendingFrames > 1`), drop the new frame and count it.

### 6.4 Encoder / decoder (`MSCodec`)
```swift
enum Codec: UInt8 { case h264 = 1, hevc = 2 }
struct VideoFormat: Codable, Equatable { var codec: Codec; var width: Int; var height: Int
  var fps: Int; var bitDepth: Int }                       // bitDepth 8 or 10
struct EncodedFrame { var data: Data            // length-prefixed NAL units as VideoToolbox emits them
  var parameterSets: [Data]?                    // non-nil only on keyframes
  var isKeyframe: Bool; var captureTimeMicros: UInt64 }
final class VideoEncoder {
  init(format: VideoFormat, bitrate: Int, output: @escaping (EncodedFrame) -> Void) throws
  func encode(_ pb: CVPixelBuffer, captureTimeMicros: UInt64)
  func setBitrate(_ bps: Int); func requestKeyframe(); var pendingFrames: Int { get }
  func invalidate()
}
final class VideoDecoder {
  init(output: @escaping (CVPixelBuffer, _ captureTimeMicros: UInt64, _ decodeMs: Double) -> Void)
  func decode(_ f: EncodedFrame) throws          // (re)creates the session when parameter sets change
  func invalidate()
}
```
Encoder session: specification `RequireHardwareAcceleratedVideoEncoder = true` and
`EnableLowLatencyRateControl = true`; if creation fails, retry once without the
low-latency key. Properties: `RealTime = true`, `AllowFrameReordering = false`,
`ProfileLevel` = `HEVC_Main_AutoLevel` / `HEVC_Main10_AutoLevel` / `H264_High_AutoLevel`,
`AverageBitRate`, `ExpectedFrameRate = fps`, `MaxKeyFrameInterval = 36000`,
`MaxFrameDelayCount = 0`, colour primaries/transfer/matrix = ITU-R 709,
`PrioritizeEncodingSpeedOverQuality = true` on macOS 13+. A property that returns an
error is logged and skipped, never fatal. Keyframes are forced with
`kVTEncodeFrameOptionKey_ForceKeyFrame`. The first frame is always a keyframe.
Decoder session: specification `RequireHardwareAcceleratedVideoDecoder = true` (retry
without it and log "software decode" if it fails); destination attributes: same NV12
pixel format (10-bit: `…420YpCbCr10BiPlanarVideoRange`), `IOSurfaceProperties = [:]`,
`MetalCompatibility = true`; flags `EnableAsynchronousDecompression`.
Format description from parameter sets via
`CMVideoFormatDescriptionCreateFromHEVCParameterSets` / `…FromH264ParameterSets`
(NAL length size 4).

### 6.5 Control channel
Bonjour: the Display advertises `_macscreen._tcp` (TXT: `id`, `name`, `v`). TCP frame:
`u32 length | u8 type | body`. Types < 0x80 carry JSON (`Codable`), types ≥ 0x80 carry
raw binary. After the handshake every body is sealed with ChaCha20-Poly1305; nonce =
4 zero bytes + u64 message counter per direction (not transmitted).

Handshake (plaintext JSON, types 1–4):
1. H→D `hello` {v, deviceId, deviceName, identityKey (Ed25519 pub), commit = SHA256(ephKeyH ‖ nonceH)}
2. D→H `helloReply` {v, deviceId, deviceName, identityKey, ephKey (X25519 pub), nonce (32 B), knowsPeer}
3. H→D `reveal` {ephKey, nonce, signature}  — D checks the commit and the signature
4. D→H `revealReply` {signature}
- Transcript `T = SHA256("MacScreen-v1" ‖ idKeyH ‖ idKeyD ‖ ephH ‖ ephD ‖ nonceH ‖ nonceD)`;
  both signatures are Ed25519 over `T`.
- Keys: `HKDF-SHA256(ikm: X25519 shared secret, salt: T, info: label, 32 bytes)` with labels
  `ctl-h2d`, `ctl-d2h`, `med-h2d`, `med-d2h`.
- Pairing, when either side does not know the other's identity key: code =
  `u32(first 4 bytes of SHA256("SAS" ‖ T)) mod 1 000 000`, shown as 6 digits full-screen on
  the Display. The user types it on the Host; the Host compares with its own value. On
  match the Host stores the Display key and sends `pairConfirm`; the Display then asks
  "Allow <host name>?" (one click or Return on the iMac) and stores the Host key.
  This needs the iMac's mouse or keyboard once, at pairing only.
- Identity keys and paired peers live in
  `~/Library/Application Support/MacScreen/identity.json`, file mode 0600.

Encrypted messages: `capabilities` (both; Display includes panel pixel size, physical
size in mm, scale, EDR headroom, hardware decoders), `probeBlob` (binary), `probeResult`,
`linkProbeStart`, `linkProbeResult`, `sessionRequest` {VideoFormat, cursorMode, audio},
`sessionAccept` {udpPort}, `reconfigure` {VideoFormat}, `cursorImage` {id, png, hotX, hotY,
widthPt, heightPt}, `hostState` {displayAsleep, mirroring}, `keepalive`, `bye` {reason}.

### 6.6 Media channel (UDP)
Packet: `u8 type | u8 0 | u16 0 | u64 counter | ciphertext | 16-byte tag`. The 12-byte
header is the AEAD associated data; nonce = 4 zero bytes + counter; key = `med-h2d` or
`med-d2h`. Receiver rejects replays with a 1024-packet sliding window. Service class
`.interactiveVideo`; `includePeerToPeer = false`.

| Type | Dir | Inner payload |
|---|---|---|
| 1 videoData, 2 videoParity | H→D | `u32 frameId, u8 flags(bit0 keyframe), u8 blockIndex, u8 blockCount, u8 0, u16 fragIndex, u16 k, u16 m, u16 0, u32 frameLength, u64 captureTimeMicros`, then fragment bytes |
| 3 audio | H→D | `u32 seq, u64 hostTimeMicros`, 960 bytes PCM |
| 4 cursor | H→D | `u32 seq, f32 x, f32 y` (0…1 in the virtual display), `u8 visible, u16 imageId` |
| 5 ping / 6 pong | both | `u32 id, u64 t0` / `u32 id, u64 t0, u64 t1, u64 t2` |
| 7 feedback | D→H | `u32 highestDecodedFrame, u32 framesDecoded, u32 framesDropped, u32 fragsReceived, u32 fragsLost, u32 fragsRecovered, u16 avgDecodeMs×10, u16 jitterMs×10, u8 flags(bit0 requestKeyframe)` |
| 8 nack | D→H | `u32 frameId, u8 blockIndex, u8 count, count × u16 fragIndex` |
| 9 linkProbe | H→D | `u32 trainId, u32 seq`, padding to 1200 bytes |

Frame payload before fragmentation: `u16 configLength | config | sample data`, where
config (keyframes only, else length 0) = `u8 count`, then per parameter set `u16 length | bytes`.

Fragmentation and FEC: split the payload into 1200-byte fragments; group consecutive
fragments into blocks of at most 64. Per block: `k` data fragments, `m` parity fragments,
`m = 0` if ratio is 0, else `min(32, max(1, ceil(k × ratio)))`. Parity is systematic
Reed–Solomon over GF(2⁸) (polynomial 0x11D, Cauchy matrix), computed over fragments
zero-padded to 1200 bytes. Data fragments are sent at true length, parity at 1200.

Receiver rules (Display):
- Keep at most 8 frames in assembly. A block is complete with any `k` of its `k+m`
  fragments; a frame is complete when all blocks are.
- Frames are decoded strictly in `frameId` order.
- If frame N is incomplete when frame N+1 completes: if RTT < 8 ms send one NACK per
  incomplete block and wait up to `2 × RTT + 2 ms`; otherwise, or on timeout, mark N lost.
- After a lost frame: set `awaitingKeyframe`, send feedback with `requestKeyframe`
  immediately (repeat every 100 ms), discard all non-keyframes, keep showing the last
  good picture.
Host rules: keep sent fragments for 500 ms (`PacketHistory`) and answer NACKs from it;
honour keyframe requests at most once per 250 ms; spread each frame's packets evenly
over up to 4 ms (pacing).

Rate control (`RateController`, evaluated once per second from feedback):
start at 60 % of the profile bitrate; if unrecovered loss is 0 and jitter < 5 ms, +5 %
(cap = profile bitrate, also ≤ 0.6 × measured throughput); if any frame was lost or
jitter > 10 ms, ×0.8 (floor 3 Mbit/s). FEC ratio: pre-FEC loss > 2 % → +0.05 (max 0.30);
< 0.2 % for 10 s → −0.05 (min: link default). At the floor for 5 s → switch to 30 fps
(`reconfigure`). Resolution is never changed automatically during a session.

### 6.7 Rendering (`MSDisplay`)
Borderless window covering the main screen (window mode with `--windowed`), content view
backed by `CAMetalLayer`: `pixelFormat = .bgra8Unorm` (`.bgr10a2Unorm` for 10-bit),
`colorspace = sRGB`, `displaySyncEnabled = true`, `maximumDrawableCount = 2`,
`framebufferOnly = true`, `drawableSize` = panel pixel size.
Decoded NV12 buffers are wrapped with `CVMetalTextureCache` (plane 0 `.r8Unorm`, plane 1
`.rg8Unorm`); the fragment shader converts BT.709 video range to RGB and samples with
linear filtering. Draw on arrival: the decoder callback stores the frame in a one-slot
mailbox and schedules `ms.render`; if a draw is in progress the newer frame replaces the
waiting one (count it as `skipped`). Record capture-to-present latency =
present time − captureTime + clock offset (from ping/pong, NTP formula).
Cursor: a `CALayer` above the Metal layer; position updates on main inside
`CATransaction` with actions disabled; images cached by `imageId`.
While connected: hold `kIOPMAssertionTypePreventUserIdleDisplaySleep`; on connect call
`IOPMAssertionDeclareUserActivity` to wake the panel. Always hold `PreventSystemSleep`.
On `hostState.displayAsleep` or disconnect: black screen, release the display assertion.

### 6.8 Cursor tracking (Host)
Timer at 120 Hz on `ms.control`: read `CGEvent(source: nil)?.location`; if inside
`CGDisplayBounds(virtualID)`, normalise and send packet type 4 only when changed (plus
one repeat every 250 ms). At 20 Hz read `NSCursor.currentSystem`; when hotspot, size or a
hash of the bitmap changes, assign a new `imageId` and send `cursorImage` on control.
`visible` = `CGCursorIsVisible()` and inside the display. Fallback mode "embedded cursor"
(setting) uses `showsCursor = true` and sends no cursor packets.

### 6.9 Audio
Driver `MacScreenAudio.driver` (C, AudioServerPlugIn, written from Apple's NullAudio
sample structure, not from GPL code): one device "MacScreen Display", 48 kHz, 2 channels,
Float32, an output stream looped back to an input stream through a ring buffer, with
volume and mute controls applied in the loopback. Installed to
`/Library/Audio/Plug-Ins/HAL/` by `install-audio-driver.sh` (asks for admin, then
restarts `coreaudiod`).
Host `AudioCapture`: open the device's input with an AUHAL unit, convert to s16le, send
240-frame packets (type 3). Needs `NSMicrophoneUsageDescription` (macOS asks once).
Menu toggle "Play sound on Display" sets the system default output to the device and
remembers the previous one; on disconnect, if the device is still default, restore it.
Display `AudioPlayer`: AUHAL output pulling from an SPSC ring buffer, target fill 25 ms.
Underrun → silence until refilled to target. Fill > target + 15 ms → drop 5 ms with a
2 ms crossfade. Missing packet → silence for that packet.

### 6.10 Auto-configuration (`MSProbe`)
Candidates are generated from the Display's panel pixel size `P`: scales
{1.0, 0.75, 0.625, 0.5} × codecs {HEVC, H.264} × 60 fps, ordered best first; 30 fps
variants are appended last. HiDPI is used when the scaled size is ≥ 0.75 × P.
Profile bitrate = width × height × fps × bitsPerPixel(codec).
1. Host: `EncodeBench` encodes 90 frames of `TestPattern` (scrolling text plus moving
   gradient, deterministic) per candidate; pass if p95 encode time < 0.5 × frame interval.
2. Each passing sample is sent as `probeBlob`. Display: `DecodeBench` decodes it paced at
   the target fps; pass if p95 decode time < 0.6 × frame interval and unpaced throughput
   ≥ 1.5 × fps.
3. `LinkProbe`: UDP trains of 0.5 s at 10, 20, 40, 80, 160 Mbit/s; usable throughput =
   highest rate with loss < 1 %.
4. `ProfileRecommender` picks the first candidate passing 1 and 2 whose bitrate ≤
   0.6 × throughput, and returns the reasons for every rejected candidate.
5. HDR is offered only if: Display reports EDR headroom > 1, 10-bit sample decodes in
   hardware, Host encodes Main10, and Gate G5 enabled HDR virtual displays.
Results are cached per (Display id, interface type). Re-run from Settings or when the
interface type changes.

## 7. App behaviour

- **Host menu (NSStatusItem):** status line; list of discovered Displays; Connect /
  Disconnect; Extend or Mirror; Play sound on Display; Run setup test; Settings…; Quit.
- **Settings (SwiftUI window):** resolution, frame rate, codec, bitrate cap, HDR toggle
  (disabled with a reason when unsupported), cursor mode, stats overlay, launch at login.
- **Display:** no Dock icon; status item with Quit and "Show pairing code"; full-screen
  window only while a Host is connected; launch at login via
  `~/Library/LaunchAgents/app.macscreen.display.plist` (written by `LoginItem`).
- **Lifecycle:** Display disconnect or control timeout → Host destroys the virtual
  display and restores audio output; reconnects automatically when the Display is seen
  again (same serial → macOS restores the arrangement). Host sleep → `bye`, teardown;
  wake → reconnect. Interface preference when both exist: wired Ethernet / Thunderbolt
  Bridge before Wi-Fi (try `requiredInterfaceType` in that order, 500 ms each).
- **Permissions:** Host checks `CGPreflightScreenCaptureAccess()` and guides the user to
  System Settings if missing. `Info.plist` has `NSLocalNetworkUsageDescription`,
  `NSBonjourServices`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion 12.0`.

## 8. Tasks

Format: **ID — title** · files · what to build · acceptance. All tasks also require
`swift build && swift test` green. "Loopback" = Host and Display roles on this Mac.

### M0 — Skeleton
- **T0.1 — Repo bootstrap.** `Package.swift` with all targets from §4.4 (each with one
  placeholder file), `LICENSE` (MIT), `README.md`, `.gitignore`, replace `PLAN.md` with
  this document, `git init`. *Accept:* `swift build` succeeds;
  `swift build -c release --arch arm64 --arch x86_64` succeeds.
- **T0.2 — MSCore.** `Constants`, `Log`, `MonoClock` (`mach_continuous_time` → µs),
  `ByteWriter`/`ByteReader` (big-endian u8/u16/u32/u64/f32/bytes, reader throws on
  underflow), `SPSCRingBuffer` (lock-free, fixed capacity, bytes), `Stats` (counters,
  rolling mean, p95 over a fixed window). *Accept:* unit tests for round-trips,
  underflow, ring wrap-around, p95.
- **T0.3 — App bundle scripts.** `Resources/Info.plist`, `make-dev-cert.sh`,
  `make-app.sh`, minimal `MacScreen` executable that shows a status item with the role
  and Quit. *Accept:* `Scripts/make-app.sh` produces `build/MacScreen.app`;
  `lipo -archs` shows `x86_64 arm64`; `codesign -dv` succeeds; app launches here.
- **T0.4 — iMac deployment (needs the user).** `deploy-display.sh` copies the app to
  `$IMAC_HOST` with `scp` and clears quarantine. User action: enable Remote Login on the
  iMac and add this Mac's SSH key (or copy the app by USB/AirDrop each time).
  *Accept:* the status item appears on the iMac.

### M1 — Probe
- **T1.1 — CodecCapabilities + ParameterSets.** List hardware encoders/decoders, query
  `VTIsHardwareDecodeSupported`, extract/build parameter sets. *Accept:* tests on Host.
- **T1.2 — VideoEncoder.** As §6.4. *Accept:* test encodes 30 generated frames at
  1920×1080 HEVC and H.264; first frame is a keyframe with parameter sets;
  `requestKeyframe` produces one within 2 frames.
- **T1.3 — VideoDecoder.** As §6.4. *Accept:* encode→decode round-trip test, 30 frames,
  output size matches, mean luma of each frame within ±3 of the source.
- **T1.4 — TestPattern, SampleFile, EncodeBench, DecodeBench.** `SampleFile` format:
  magic `MSV1`, JSON `VideoFormat` with u32 length, then per frame `u8 key | u32 length |
  frame payload (§6.6)`. *Accept:* bench results deterministic in structure; tests on a
  640×360 sample.
- **T1.5 — `msprobe` CLI.** Commands: `caps`, `encode --width --height --fps --codec
  --bits --out`, `decode <file>`, `candidates --panel WxH` (encodes the whole ladder into
  a folder). JSON output. *Accept:* run on Host; then user runs `caps` and `decode` for
  every ladder file on the iMac and returns the JSON. **→ Gate G1.**

### M2 — First picture
- **T2.1 — ReedSolomon.** GF(2⁸) tables, `encode(data:[k], m) -> parity`,
  `reconstruct(shards:[k+m] with nils)`. *Accept:* tests: every loss pattern up to `m`
  for (k,m) ∈ {(1,1),(8,2),(64,32)} on random data; more than `m` losses returns failure.
- **T2.2 — Packet codecs.** `PacketHeader` and all inner payloads of §6.6. *Accept:*
  encode/decode round-trip and truncated-input tests for every type.
- **T2.3 — Fragmenter + Reassembler.** As §6.6, pure logic, time injected. *Accept:*
  tests: sizes 1 B, 1200 B, 1201 B, 1 MB; random order; duplicates; loss recovered by
  FEC; loss beyond FEC → lost-frame event and `awaitingKeyframe`; NACK path with
  simulated RTT; never more than 8 frames held.
- **T2.4 — Handshake, PacketCipher, ReplayWindow, IdentityStore.** As §6.5–6.6.
  *Accept:* two in-memory peers derive equal keys; tampered commit, signature or
  ciphertext is rejected; pairing codes match; replayed packet rejected; file mode 0600.
- **T2.5 — Discovery + ControlChannel.** `NWListener`/`NWBrowser`, framing, keepalive,
  timeout, `Codable` messages. *Accept:* localhost test: discover, handshake, exchange
  each message type, timeout fires after 5 s of silence.
- **T2.6 — MediaChannel + PingClock.** UDP send/receive with cipher, type dispatch,
  batch send with pacing, RTT and clock offset. *Accept:* localhost test: 10 000 packets
  at 50 Mbit/s with zero loss; offset within ±1 ms on the same machine.
- **T2.7 — VirtualDisplay.** As §6.1–6.2. *Accept (manual, Fable):* a display appears
  in System Settings at 1920×1080 HiDPI, survives 60 s, disappears on `destroy()`;
  mirror on/off works.
- **T2.8 — ScreenCapturer.** As §6.3. *Accept (manual):* frames arrive at ≤ 60 fps
  while a window moves on the virtual display, none while idle; pixel format is NV12.
- **T2.9 — MetalRenderer + DisplayWindow.** As §6.7 without cursor. *Accept:* test app
  mode renders `TestPattern` buffers at 60 fps in a window with correct colours
  (pixel readback of colour bars within ±2).
- **T2.10 — HostSession + DisplaySession.** State machines wiring everything:
  discover → handshake → (pair) → capabilities → sessionRequest/Accept → streaming →
  teardown. Keyframe-request recovery only (no NACK, FEC ratio from constants).
  *Accept:* loopback on this Mac with `--windowed` shows the virtual display live.
- **T2.11 — Minimal UI.** Role chooser, Host menu (list, connect, disconnect), pairing
  code screen and entry, permission guidance, stats overlay. *Accept:* loopback driven
  entirely from the UI. Then deploy to the iMac. **→ Gate G2.**

### M3 — Feel wired
- **T3.1 — CursorTracker + CursorLayer** (§6.8, §6.7).
- **T3.2 — PacketHistory + NACK handling** on both sides.
- **T3.3 — RateController + adaptive FEC + `reconfigure`** (§6.6).
- **T3.4 — Network simulator test.** In-process lossy/jittery channel between
  Fragmenter and Reassembler with real encoder/decoder; scenarios: 0 %, 1 %, 5 % random
  loss, 20 ms bursts. *Accept:* 0 % and 1 % give zero lost frames; every scenario
  recovers a clean picture within 500 ms of the loss.
- **T3.5 — Interface preference + reconnect logic** (§7 lifecycle).
- **T3.6 — Latency instrumentation.** Signposts per stage, overlay with
  capture→present p50/p95, CSV export. **→ Gate G3** (Fable tunes pacing, jitter wait,
  FEC defaults from iMac measurements; evaluates text sharpness and long-term-reference
  recovery as optional follow-up tasks).

### M4 — App experience
- **T4.1 — In-app probe + ProfileRecommender + LinkProbe** (§6.10) with result UI.
- **T4.2 — Settings window + persistence.**
- **T4.3 — Display lifecycle:** LoginItem (LaunchAgent), power assertions, wake on
  connect, idle/black states, `hostState`.
- **T4.4 — Host lifecycle:** sleep/wake, auto-reconnect, mirror/extend toggle, display
  arrangement persistence check.

### M5 — Audio
- **T5.1 — Driver + build/install/uninstall scripts.** **→ Gate G4** (does it load when
  signed ad-hoc or with the dev certificate on macOS 27).
- **T5.2 — AudioCapture + output switching.**
- **T5.3 — AudioPlayer + drift handling.** *Accept:* 30-minute playback on the iMac
  without audible glitches; audio delay within 60 ms of video (clap test video).

### M6 — Colour and HDR
- **T6.1 — P3 path:** P3 primaries on the virtual display, capture colour space and
  layer colour space Display P3 when the Display panel is P3.
- **T6.2 — HDR spike (Fable-led). → Gate G5.** If a virtual display cannot advertise
  HDR on current macOS, HDR stays hidden and the plan ends at 10-bit SDR.
- **T6.3 — 10-bit / HDR pipeline** only if G5 passes.

### M7 — Release preparation
- **T7.1 — Docs:** build from source, permissions, pairing, troubleshooting, threat
  model, known limits (private API, no notarization).
- **T7.2 — Cleanup pass:** dead code, warnings, `swift test` in CI-ready script.

## 9. Decision gates (Fable only)

| Gate | Input | Decides |
|---|---|---|
| G1 | iMac `msprobe` JSON | default ladder for this iMac; whether 5K is reachable; codec |
| G2 | first live session on the iMac | picture correctness, HiDPI behaviour, cursor mode default |
| G3 | latency CSV on Wi-Fi and wired | pacing, jitter wait, FEC defaults; optional sharpness and LTR work |
| G4 | driver load result | signing approach for the audio driver, or fallback design |
| G5 | HDR spike | ship, mark experimental, or drop HDR |

## 10. Verification

- **Every task:** `swift build`, `swift test`, zero warnings in touched files.
- **Loopback (this Mac):** `open build/MacScreen.app --args --role display --windowed`
  plus a second instance `--role host`; move windows on the virtual display; overlay
  shows 60 fps.
- **iMac, Wi-Fi (M3 exit):** capture→present p95 < 30 ms and under 40 ms glass-to-glass
  (240 fps phone video of a flashing square on both screens); no artefact lasting longer
  than 0.5 s during a 10-minute session with video playing and windows dragged.
- **iMac, wired (M3 exit):** glass-to-glass under 25 ms; zero lost frames in 10 minutes.
- **Efficiency:** idle desktop → Host app CPU < 2 %, no packets except keepalives;
  streaming 4K60 → Host app CPU < 25 % of one core, Display decode within budget.
- **Robustness:** Wi-Fi off/on, iMac app quit/relaunch, Host sleep/wake, Host display
  lock: each reconnects without user action within 10 s.
- **Security:** wrong pairing code refused; unpaired Host cannot start a session;
  packet capture shows no plaintext.
- **Final:** all of the above on a clean user account on both Macs, following only the
  README.

## 11. Out of scope
Input from the Display Mac, AirPlay, Mac App Store, notarization (until a paid account
exists), more than one Display at a time, Host macOS older than 12.3.
