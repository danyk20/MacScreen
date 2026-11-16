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
