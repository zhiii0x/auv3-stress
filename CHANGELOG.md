# Changelog

## 0.1.0

The first release.

- 21 sections of checks on an Audio Unit hosted out of process: sample rates and block sizes,
  the transport, parameter fuzz, automation and MIDI inside render, state (saved, restored,
  loaded while rendering, corrupted), threads, several instances and their independence,
  open/close cycles, render time on a real-time thread, channel layouts, the timeline (cycles,
  pre-roll, a render clock past 2³¹ and 2³² samples, offline), tail, reset, latency and bypass,
  hostile input, MIDI abuse, clicks on parameter jumps, pitch across sample rates, the editor,
  and the extension's crash reports.
- Scenarios in JSON (`--scenario`), with a spectrogram (`--spectrogram`).
- Reports as JSON (`--json`) and JUnit XML (`--junit`); `--strict` makes warnings fail.
- Seeded runs (`--seed`), WAV files of what was rendered (`--save-audio`), a picture of the
  editor (`--snapshot`, `--window-size`).
