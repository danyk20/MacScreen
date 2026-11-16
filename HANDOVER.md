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

## Status (2026-11-16 evening)

T2.10a, T2.10 and T2.11 committed; all tests pass. Never run live yet: UI untested, DisplayCaptureSource
(virtual display + ScreenCapturer) never captured, idle-screen recovery untested.
LOOPBACK CONFIRMED by user (2026-11-17): virtual display live in --windowed Display, window arrangement works, feels fast. Dev cert installed. Private repo danyk20/MacScreen pushed (HTTPS via gh); push after each task.
T3.2, T3.3 committed; T3.4 in progress. Remaining M3: T3.1 cursor, T3.5, T3.6, then G2/G3 need iMac.
(Old note: loopback run (ask user: make-dev-cert.sh, Screen Recording, confirm picture). Run commands:
`build/MacScreen.app/Contents/MacOS/MacScreen --role display --windowed --stats` and
`... --role host --stats`; in Host's "MS" menu choose Connect, type the code, Allow on the Display.
Then: user wants a private GitHub repo under their profile created, committed and pushed at the end
of this stretch (ask repo name first; check gh auth; no secrets/build artifacts).
Then M3 (NACK ignored until T3.2; Display passes rttMs nil to Reassembler).

## Waiting on the user

- Probe run on the iMac: copy `build/imac-probe.zip` there, unzip, then in that folder run
  `xattr -dr com.apple.quarantine .` and `./msprobe decode-all ladder > imac-result.json`.
  The result feeds Gate G1 (default resolution and codec). Alternative: user enables Remote Login.
- Screen Recording permission for `build/MacScreen.app` at the first loopback test.
