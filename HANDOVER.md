# MacScreen — handover (2026-11-16)

Read `PLAN.md` first; it is the specification. This note only records state and working rules.

## Working rules (set by the user)

- Main session runs on a cheap model (Sonnet). It hands out tasks, checks results, talks to the user.
- Easy implementation → Haiku subagent. Difficult implementation → Sonnet subagent.
- Debugging → Opus subagent.
- Architecture decisions → Fable subagent, one focused question per call. Use Fable for nothing else.
- Every subagent runs at **medium** effort.
- Keep briefs short: task ID + `PLAN.md` sections. Put missing detail into `PLAN.md` once.
- Every brief has a hard budget: a time limit and at most 3 fix-and-retest attempts, then stop and report.
- Do not wait blindly on a subagent. Tasks here normally take 2–6 minutes; check on anything much
  longer, stop it if it loops, and hand the problem to an Opus subagent.
- Review by test output and diff summary, not by reading whole files.
- One local commit per task (`T<id>: <title>`), no push.
- To read test results: `swift test 2>&1 | grep -E "Executed [1-9][0-9]* tests|error|failed" | sort -u`

## Done and committed

M0 (T0.1–T0.3), M1 (T1.1–T1.5), M2 T2.1–T2.9. All unit tests pass on the Host (Apple M2, macOS 27).

Decisions made after the plan was written (already reflected in `PLAN.md` and code):
- HEVC encoder does **not** use low-latency rate control (12 ms per 4K frame without it, 21 ms with it);
  H.264 does. 5K60 cannot be encoded in real time on the M2; 4K60 is the realistic top setting.
- Benchmarks exclude the first 10 frames; encode pass rule is p95 < 0.85 × frame interval.
- No H.264 candidates above 4096×2304.
- CLI target folder is `Sources/MSProbeCLI` (binary `msprobe`).

Known gaps:
- `ScreenCapturer` has never actually captured: its tests skip without Screen Recording permission.
  First real run is the loopback test through the signed app.
- In a non-GUI process (xctest) `CGDisplayCopyDisplayMode` returns nil for a new virtual display;
  the tests fall back to `system_profiler`. Check that it works inside the real app.
- `Scripts/make-dev-cert.sh` has not been run yet (adds a self-signed certificate to the login
  keychain; needed so Screen Recording permission survives rebuilds). Ask the user before running.
- `Reassembler.fragsLostEstimate` over-counts with FEC on; real loss should come from packet
  counter gaps (do this in T3.3).

## Status (2026-11-17, after unattended run)

Committed and pushed to private repo danyk20/MacScreen (HTTPS remote): M0, M1, M2 (T2.1-T2.11),
M3 T3.1-T3.6, M4 T4.1-T4.4, M5 T5.1-T5.3 (driver written+compiled, NOT installed), T6.1 (P3),
T7.1 (docs), T7.2 (cleanup, Scripts/test.sh, Scripts/deploy-display.sh). 0 build warnings.
Loopback on this Mac confirmed live by the user (virtual display, --windowed, fast).
Not done: T6.2/T6.3 (HDR, Gate G5), anything needing the iMac.

### First live session on the iMac (2026-11-17)
Paired and streaming over Wi-Fi (HEVC 4K60 default, G1 applied). Gateway 192.168.43.1 (hotspot-like,
slow router, 86 ms avg ping to iMac); iMac Ethernet not connected. Baseline capture->present p50 83 /
p95 147 ms; render stage 34.7 ms. Tuning: vsync OFF by default on Display cut render to ~7 ms and
capture->present p50 to ~53-57 ms (p95 ~125-140, mostly Wi-Fi jitter). USER MUST CHECK FOR TEARING;
restore with `defaults write app.macscreen.MacScreen msRenderVsync -bool YES` (or -msRenderVsync YES).
Other settings: msRenderDrawables (2), msRenderStreamSize (off). Next: wired/5GHz link, G3 with
wired CSV, tearing check (G2 decision). Bug fixed: Allow alert hidden behind full-screen Display window.
iMac state: app in ~/Applications/MacScreen.app (user osx, ssh alias iMac5K), not running.

### Session 2026-11-17 (later): live tuning on the iMac
- Fable is out of usage credits until Sun Nov 22 03:00. Provisional decision P1 (Opus) in PLAN.md after the G1
  note needs Fable review. Pending Fable questions: intra-refresh/LTR vs Display jitter buffer; re-measure
  mid-session; jitter thresholds 10/25 ms; G3 (needs wired CSV), G4 (driver), G5 (HDR).
- Link is now measured on EVERY connection (HostController.runLinkCheck, ~2 s, 'Measuring link...'); cache only
  as FALLBACK keyed by gateway. On Beachclub Wi-Fi: 37-40 Mbit/s measured, 4K60 at 22-24 Mbit/s, presented
  55-56 fps, capture->present p50 59-63 / p95 ~140 ms. Encoder (27 ms/4K frame, 2 in flight) is the fps limit;
  3200x1800@60 would likely hit a steady 60 (untested, user may want it as Wi-Fi default).
- Not tested live: final rebuild with `msAutoLinkProbe NO` switch, FALLBACK path, pairing during the check,
  tearing check with vsync off (restore: defaults write app.macscreen.MacScreen msRenderVsync -bool YES).
- Fixed: ControlChannel bye-before-cancel bug (Display stayed 'busy' ~5 s after Host stop).
- Keychain: click 'Always Allow' on the codesign prompt to stop repeated password prompts.

### Later on 2026-11-17 (no iMac access any more)
- FPS cap root cause: ScreenCapturer minimum frame interval was exactly 1/60 s, dropping ~4 fps; now 90% of
  1/fps -> 60 fps at 4K in loopback (0142e41). Encoder is not the limit (27 ms encMs is latency with 2 frames
  in flight). RE-CHECK 60 fps on the iMac. 3200x1800 would only save ~4 ms latency.
- Security pass (fdccd2f): ~60 hostile-input/fuzz tests, 7 bugs fixed. Unfixed findings: device name/id/knowsPeer not in
  signed transcript (low, changes wire transcript); (FIXED later: Display DoS via unauthenticated connections - 3 s handshake timeout, cap 4 unsecured links,
  per-IP rate limit, only secured links take the session slot; Allow-dialog loop - one dialog per link, 60 s denial
  cooldown; identity dir 0700. Still open: an unpaired Host that completed the handshake can hold the slot with
  keepalives); authenticated frames up to 64 MB (low); NACK amplification for empty block 0 (low);
  Reassembler frame ID not wrap-safe at 2^32 (info); identity dir mode 0755 (info).

### Live verified on the iMac (2026-11-17 evening)
- Final build streams 4K60: presented exactly 60 fps in every 10 s window under continuous motion; capture->present
  p50 60 / p95 141 ms; render 6.4 ms; decode 4.7 ms; link check 52 Mbit/s -> 4K60 @30 Mbit/s; another connection on
  a worse moment of the link chose 3200x1800@60 @18 Mbit/s (policy works). Wi-Fi was flaky at times (ping up to 278 ms,
  two 'could not connect' retries) - keep the iMac screen awake (caffeinate -u -t 2 over ssh before connecting).
- Cursor overlay mode (--cursor overlay) verified by user: cursor, shapes, leaving the display all fine.
- Mirror toggle verified by user (on/off both fine) after the VPN on the iMac was turned off (link check 54 Mbit/s -> 4K60).
- Sleep/wake verified (2026-11-17 20:47): Host ended session on sleep, auto-reconnected after wake without pairing, re-ran link check, streaming 4K60 again.
- Still not verified live: settings window, setup-test UI, login item, audio, tearing
  (user did not report tearing; vsync stays off), G3/G4/G5, Fable review of P1.

### iMac VPN problem (found 2026-11-17 20:4x)
Host could not connect: a CyberGhost IKEv2 VPN on the iMac (connect-on-demand) was stuck in 'connecting' and silently
dropped replies to new TCP connections (listener queue full of SYN_RCVD; ssh port 22 still worked; MacScreen port
timed out). Not a MacScreen bug. Fix on the iMac (user): quit/disconnect CyberGhost or disable its on-demand, or
exclude local networks. Check before connecting: `ssh iMac5K 'scutil --nc list'`.

### Audio driver (Gate G4 PASSED 2026-11-17 22:0x: ad-hoc signed driver loads on macOS 27, device 'MacScreen Display' visible; end-to-end sound to iMac VERIFIED by user 2026-11-17: works, good quality and sync; mic permission prompt appears on first use; setting applies from next connection; still to do: 30-min playback test, clap test)
First install loaded but the device never appeared: Driver-Service log said 'dlsym cannot find symbol MacScreenAudio_Create'
(-fvisibility=hidden hid the factory). Fixed with visibility("default"); AudioDriver/tests/driver_harness.c (74 selectors x 6
objects + IO loopback) runs on every build. User must reinstall: `Scripts/install-audio-driver.sh` (sudo), then
`system_profiler SPAudioDataType | grep -A3 'MacScreen Display'`. Remaining risk: macOS 27 may reject the ad-hoc signature in the
Driver-Service helper (log: `log show --last 2m --predicate 'process == "coreaudiod" OR process CONTAINS "Driver"'`); then sign with
'MacScreen Dev' or Developer ID.

### Settings gotcha
Settings 'Display native (5K, static work)' (maxHeight 0) overrides the link-based 4K60 choice and gives 5120x2880@60 at only the link cap
(~24 Mbit/s). User tried it while testing the Settings window; reset to the 4K option for normal use.

### Pending decision gates (Fable only, one question per call)
G1 needs iMac `msprobe` JSON; G2 first live iMac session; G3 latency CSV on Wi-Fi + wired;
G4 driver load result on macOS 27; G5 HDR spike.

### iMac checklist, in order (needs the user)
1. Probe: copy build/imac-probe.zip to iMac, unzip, `xattr -dr com.apple.quarantine .`,
   `./msprobe decode-all ladder > imac-result.json` -> G1.
2. Deploy: enable Remote Login on iMac, `Scripts/deploy-display.sh user@imac.local`
   (or copy build/MacScreen.app manually), launch `--role display`. Host: `--role host --stats
   --connect <iMac name>`. Pairing: code on Display, type on Host, Allow on iMac -> G2.
3. Run "Run setup test" from the Host menu; check Settings; try `--cursor overlay`.
4. Latency: `--latency-csv`, wired and Wi-Fi -> G3.
5. Audio (experimental): Scripts/build-audio-driver.sh (click "Always Allow" on the keychain
   prompt once), Scripts/install-audio-driver.sh (sudo, restarts coreaudiod) -> G4; 30 min
   playback + clap test.

### Known gaps / unverified live
- Audio buffer target: AudioPlayer uses 40 ms, MSConstants.audioTargetBufferMs and PLAN 6.9 say
  25 ms; reconcile at G3.
- Dev-cert codesign can hang waiting for a keychain prompt (Always Allow once).
- ScreenCapturerTests skip when the main display is asleep/locked; never seen capturing in tests.
- Never run live: sleep/wake teardown+reconnect, mirror toggle, cursor overlay, settings UI,
  setup-test UI, login item, power assertions, P3 on a real P3 panel, AUHAL/driver, wired->Wi-Fi
  fallback, NACK/rate control on a real network.
- Menu bar item "MS" is invisible if the menu bar is full or the frontmost app is full screen;
  use `--connect` as a workaround.
- Real HDR: plan says only if a virtual display can advertise it (G5).

## Waiting on the user

- Probe run on the iMac: copy `build/imac-probe.zip` there, unzip, then in that folder run
  `xattr -dr com.apple.quarantine .` and `./msprobe decode-all ladder > imac-result.json`.
  The result feeds Gate G1 (default resolution and codec). Alternative: user enables Remote Login.
- Screen Recording permission for `build/MacScreen.app` at the first loopback test.
