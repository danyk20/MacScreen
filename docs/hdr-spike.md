# HDR spike (T6.2, Gate G5)

Host: Apple M2, macOS 27.2.1. Date: 2026-11-18. Display (iMac 5K, i5-6500, macOS 12.7.6) was **not reachable**
(`ssh iMac5K`: connect timed out), so every Display-side fact below comes from `docs/imac-probe-result.json` or is
marked unverified. Scripts: `Scripts/spikes/` (not part of the build). 15 short virtual-display runs, each destroyed
at the end of the run; no production code or constants changed.

## 1. Can a CGVirtualDisplay advertise HDR/EDR? Yes.

Runtime dump (`swift Scripts/spikes/dump-cgvd-runtime.swift`) shows private surface not in `CPrivateAPI.h`:

| Class | Extra members on macOS 27 |
|---|---|
| `CGVirtualDisplayMode` | `-initWithWidth:height:refreshRate:transferFunction:`, `transferFunction` (uint32, default 0) |
| `CGVirtualDisplayDescriptor` | `displayInfo` (dict of `Display*PointX/Y` primaries), `-setDisplayInfoValue:forKey:`, `serialNumber`, `dispatchQueue` |
| `CGVirtualDisplaySettings` | `refreshDeadline`, `isReference`, `rotation` |
| `SLVirtualDisplay*` (SkyLight) | newer parallel API: `SLVirtualDisplayMode.eotf`, `.options`, `+SLVirtualDisplay capabilities` |

No descriptor/settings key named HDR, EDR, luminance or pixel depth exists; HDR is selected **per mode** by
`transferFunction`. Screen Sharing's own config logs `numVirtualDisplays … hdr: %d`, so Apple uses this path itself.

Empirical (`Scripts/spikes/hdr-vd-probe.swift <tf> <capture>`; 1920x1080@60, hiDPI 0):

| transferFunction | NSScreen maxPotentialEDR / maxEDR | CGDisplayCopyColorSpace | NSScreen bpp |
|---|---|---|---|
| 0 (current production) | 1.0 / 1.0 | unnamed, not HDR | 24 |
| **1** | **5.0 / 5.0** | unnamed, not HDR | 24 |
| 2, 3, 4 | 1.0 / 1.0 | unnamed, not HDR | 24 |

`transferFunction = 1` makes WindowServer treat the virtual display as an EDR display with 5.0x headroom (PQ-class).
`system_profiler` not needed: the headroom is the authoritative signal. `maximumReferenceEDR` is 0 (no reference mode).

ScreenCaptureKit from the same display (first buffer):

| Display tf | SCK config | Delivered | Attachments |
|---|---|---|---|
| 1 | preset `.captureHDRStreamLocalDisplay` | `xf44` 10-bit 4:4:4 full | PQ (ST 2084), P3-D65, matrix 709, cs `DisplayP3_PQ` |
| 1 | preset `.captureHDRStreamCanonicalDisplay` | `xf44` | same |
| 1 | HDR local + `pixelFormat = x420` | **`x420` 10-bit 4:2:0 video** (encoder-ready) | PQ, P3-D65, 709; desktop luma codes 193..422 |
| 1 | SDR, `l10r` | `l10r` | none |
| 0 | SDR, `l10r` | `l10r` | none |
| 0 | SDR, `x420` | `x420` | none; luma codes 183..601 |

So HDR capture works end to end on the Host. Caveats: primaries are P3 (not BT.2020) with a 709 matrix, so the
encoder VUI must say P3/PQ (or the Host converts to BT.2020); desktop content stays near SDR white unless an app
draws EDR content.

## 2. Main10 encode (Host) and decode

`msprobe caps`: HW HEVC encoder `ave.hevc`. `msprobe encode --codec hevc --bits 10` (existing `VideoEncoder`,
`kVTProfileLevel_HEVC_Main10_AutoLevel`, `x420` input), 60 fps, 90 frames:

| Size | 8-bit mean / p95 ms | 10-bit mean / p95 ms | Pass (p95 < 14.17 ms) |
|---|---|---|---|
| 3840x2160 | 11.20 / 12.02 | 12.23 / 13.11 (two runs: 13.11, 13.20) | both pass; 10-bit is ~9 % slower |
| 5120x2880 | 97.6 / 126.4 | 127.3 / 136.5 | both fail (known M2 limit) |

Hardware encode = true for 10-bit. Same bitrate gives the same size (1.14 MB vs 1.16 MB for 90 frames).
Local decode of the 10-bit samples on the M2: hardware, 1.74 ms (4K), 2.74 ms (5K).

**iMac 10-bit decode: unverified.** The probe JSON only has 8-bit results (`hwDecodeHEVC: true`). The iMac CPU is a
Skylake i5-6500; Apple's HEVC Main10 hardware decode starts with Kaby Lake (7th gen), so a software or hybrid
Main10 decode at 4K–5K60 is likely too slow. Must be measured with `msprobe encode --bits 10` → `msprobe decode`
on the iMac before anything 10-bit is offered (PLAN §6.10 step 5 already gates on this).

## 3. 10-bit SDR end to end

Every Host stage works here: SCK `x420`/`l10r` from a tf=0 display, HW Main10 at 4K60 within budget. Production
already has the switches (`ScreenCapturer` `tenBit`, `VideoEncoder` bitDepth 10, `MetalRenderer` `bgr10a2Unorm`).
The only unknown is the iMac Main10 decode speed (see 2).

## Recommendation for G5

- **HDR: drop for v1 (keep the finding as "experimental, off").** A virtual display *can* be HDR (`transferFunction
  = 1`, headroom 5.0, PQ capture works), so the technical gate passes on the Host. But the only Display is a
  ~500-nit SDR iMac panel with 1.875 headroom, likely without HW Main10 decode, and HDR needs a private initialiser,
  PQ VUI/metadata, EDR tone mapping on the Display. Little visible gain for real cost and risk. Revisit if a real HDR
  Display appears.
- **10-bit SDR: worth one measurement, not more yet.** Run `msprobe decode` on a 4K60 Main10 sample on the iMac. If
  p95 < 0.6 × frame interval in hardware, expose 10-bit SDR as an opt-in (≤ 4K, HEVC only, ~9 % encoder cost). If it
  is software decode, drop 10-bit too.

## Commands

```
swift Scripts/spikes/dump-cgvd-runtime.swift                   # runtime surface, no display created
swiftc -O -o /tmp/hdr-vd-probe Scripts/spikes/hdr-vd-probe.swift
/tmp/hdr-vd-probe 1 hdrlocal420                                 # tf, capture: none|sdr10|sdr420|hdrlocal|hdrcanon|hdrlocal420
swift build --product msprobe && .build/debug/msprobe encode --width 3840 --height 2160 --fps 60 --codec hevc --bits 10 --frames 90 --out s.bin
.build/debug/msprobe decode s.bin
```
