# WHOOP MG: haptics and the live ECG stream, as measured

What the band does that the gesture code depends on and no spec describes.
Everything here comes from the Device lab logs on one WHOOP MG, firmware as of
2026-10-02. Each item says how sure it is and which log showed it. When a new
lab run disagrees, update this file, the virtual band
(`test/support/virtual_mg.dart`) and then the code, in that order.

Logs referred to:

- **L1**: 2026-10-02 16:53–17:00, 10 ECG-touch sessions and 6 repeated-double-tap
  sessions, the old flow (two-pulse acknowledgement, then a touch window).
- **L2**: 2026-10-02 18:17–18:20, 5 ECG-touch sessions on the new flow (count
  buzz first, one clock). Reconstructed as
  `test/fixtures/ecg_traces/2026-10-02_1817_lab.txt`.

## Clocks

| Finding | Confidence | Evidence |
|---|---|---|
| An R17 packet's strap time is its **newest** sample. Its samples run back from it, 10 ms apart. | High | L1: read as the first sample, every packet reached the phone ~0.8 s before its last sample existed, while the strap clock matched the phone to ~20 ms (event 113 vs packet 1). The short first packet then looked like a 510 ms hole; read as the newest sample it is continuous. The protocol calls it the "acquisition-cycle time". |
| Packets reach the phone ~0.13–0.19 s after their newest sample. | High | L1 receipt minus strap time, with the strap clock near the phone's. |
| The strap clock's offset from the phone moves: ~0.15 s behind at 16:53, ~0.82 s **ahead** at 18:17 (band events then showed "−0.8 s after it happened"). | High | L1 and L2 event 113 vs receipt. |
| Consequence: gesture timing runs on the sample clock only. Phone time is used for stall detection and buzz pacing, never to place a touch window. | Rule | `ecg_tap_session.dart` |

## The ECG stream

| Finding | Confidence | Evidence |
|---|---|---|
| Packets: one with 0 samples (sometimes two, when the start was slow), then one with 49 samples, then 100 samples each, one per second. | High | L1, L2, every session. |
| A finger already on the sensor shows as 13 samples (36–48) of the 49-sample packet, then a fully zero packet, then contact from **sample 86** of the next, ~2.35 s after the first sample. With no finger, all zeros. | High | Identical in every touching session of L1 and L2. |
| So "zero" does not mean "no finger" for the first ~2.4 s. The first window opens 2.5 s after the first sample (`sensorSettle`). | Rule | |
| A lift shows as zeros almost at once (≤ ~0.2 s after the wearer felt the buzz, reaction time included). | Medium | L2 18:17:57: buzz started at phone 18:18:04.33 (event 60), zeros from 04.55. |
| A finger that comes back after a lift shows **late**: 1.96 s and 2.16 s after the lift, both at **sample 76** of a packet. | Medium (2 cases) | L2 18:19:10 and 18:19:41. The real re-touch times were not logged. |
| Model: the band checks for a returning finger once per packet (240 ms before its end). A finger back at T after a lift at L shows at the first check at or after max(T, L + hold), with hold between 1.16 s and 1.96 s (1.5 s in the model). | Fitted | Both L2 re-touches; the checks one packet earlier did not show them. |
| Consequence: after a lift the next window gets `sensorReacquire` (1.5 s) on top of gap + confirm. A tap shorter than the sensor's blind time is invisible. | Rule | Replay of L2 18:19:10 counts tap 4 with it and 3 without it. |
| While touching, 96–100 of 100 samples are non-zero (the trace crosses zero). | High | L1, L2. |
| Each packet also carries the band's own electrode **presence** bit (flags bit 3, debounced by the band), the HeartKey S2 state, progress, quality and an unreadable mask. These were not logged before 8V; every packet line now shows them. | Protocol | `openstrap_protocol` `labrador.dart` |
| The ECG **reading** state machine ends a capture after 3 contact losses, and sends an explicit RESTART when the S2 state drops with presence on (and drops packets while the restart runs). A gesture lifts its finger by design, so with `persist: false` neither happens; both are logged instead. | Rule | `ecg_controller.dart`, `ecg_policy.dart` |

## Haptics

| Finding | Confidence | Evidence |
|---|---|---|
| Each pulse of a multi-pulse buzz is its own band command (300 ms apart). Two such pulses are felt as two. | High | The wearer, L1. |
| The band takes a command when idle and then stays busy. Within that time it takes **one** more (played after the first) and drops the rest **with no reply**. | Medium | L2: every three-pulse buzz got "pending" replies for pulses 1–2 and "No reply" for pulse 3. L1: the tap-3 buzz, sent ~1 s into the two-pulse acknowledgement, got no reply and no band event, 6 of 7 times. |
| The busy time, from the first command's write: a command written ~1.25 s after the first of a pair was dropped; one written ~2.0 s after played. | Medium | L1 16:57:43 (dropped) and 16:59:52 (played); first-pulse write times from their reply latencies. |
| Band events 60 and 100 bracket a buzz: 60 ~0.3 s after the first command, 100 ~1.05–1.5 s after 60, for one pulse or two. 114 follows the stream stop. 113 is the stream start (its time equals the first packet's strap time). | Medium | L1, L2. What 60/100 mean exactly is unknown. |
| Consequence: a buzz goes out in bursts of at most two pulses (`maxPulsesPerBurst`), and no burst is asked for within 1.8 s of the previous burst's last write (`buzzQuietGap`, ~2.15 s after the first pulse). A three-pulse count buzz is felt as "buzz buzz … buzz". | Rule | The virtual band plays every pulse a four-tap gesture asks for. |

## Start-up cost

From double tap to the first packet: 0.7–2.8 s. From double tap to a decided
count of 2 (no finger): about 5–7 s. Where it goes:

| Stage | Time | Can it be shorter? |
|---|---|---|
| Tap to phone | 0.13–0.3 s | No (band). |
| ECG start chain on the phone (wrist, guard, pause history sync, prepare, start) | 0.5–1.2 s; five times 2.6–3.3 s, with the first packet arriving before the start answered | Partly. Each stage is now timed in the lab trace ("ECG start: … (+N ms)"); the slow runs need that data first. |
| First packet to settled sensor | ~2.4 s | No (band). |
| Packet cadence | 1 s | No, unless the band has a faster mode (a protocol question). |
| Buzz write | 0.09–0.9 s | Maybe: slow writes look queued behind other commands. |

## Measuring more: the Device lab probes

Under Devices → your band → Device lab → Hardware probes. Both start only from
their button, stop at once on Stop or when you leave the screen, and write
everything into the lab log ("Copy all logs").

- **Buzz probe.** Eight groups of three single buzzes, 200 ms to 1600 ms apart
  (at most 30 buzzes per run, a 2 s rest after each group). After each group
  it asks how many you felt. The log line per group has, for each command, when
  it was asked for and written, the band's reply (or `none`), and the band
  events seen, in ms from the group's start. This pins down the busy window and
  whether queued pulses play.
- **ECG touch probe.** Streams for at most 60 s. After the sensor settles the
  screen (and the phone's own vibration) cues: keep off, then touch-and-hold /
  lift with lifts of 0.4, 0.8, 1.5, 2.5 and 2 s, then three quick taps. The
  log ends with every contact run (and where in its packet it started), every
  change of the band's presence bit, and for each cue how long after it the
  sensor showed the change. Cue times are mapped onto the strap clock through
  the least-delayed packet, so each latency includes your reaction time and the
  best packet's own latency (~0.15 s).

Safety and hardware health: the probes send nothing the app does not already
send (one ordinary buzz; the gesture's ECG start and stop). The buzz count per
run is capped and rested. The ECG stream is capped and always stopped, also on
errors. No sample leaves RAM unless you copy the log (invariant 14).

## Replaying off the band

The lab keeps the last ~6 minutes of ECG packets (raw samples and status
bytes). "Copy all logs" ends with an `ECG packets` section, one `r17v1` line
per packet. Save it under `test/fixtures/ecg_traces/` and:

```dart
final trace = Trace.load('test/fixtures/ecg_traces/<file>.txt');
final r = await replayTrace(trace.of('tap 18:19:10.695'),
    thresholds: thresholdsOf('start 500 ms, gap 200 ms, confirm 1000 ms'));
```

`test/hardware/lab_trace_replay_test.dart` replays L2 both ways. To try an
idea without any recording, script a wearer on the virtual band
(`test/hardware/virtual_mg_test.dart`): finger-on intervals in, packets with
receipt times out, and a haptic queue that drops what the real one dropped.

## Open questions (what the next lab run should answer)

1. Does the presence bit go off and on faster than the samples? If it does,
   contact can come from it and the reacquire wait shrinks. (ECG probe; every
   packet line now shows it.)
2. The reacquire hold: 1.16–1.96 s from two cases. (ECG probe: lifts of 0.4,
   0.8, 1.5 and 2.5 s.)
3. Do short taps (300 ms) after a lift ever show? (ECG probe, last three cues.)
4. The haptic busy window, and whether a third command is always dropped or
   only sometimes. (Buzz probe.)
5. Does the band keep streaming without the reading's RESTART? (Every gesture
   now; the trace says "a reading would send RESTART here" when it would have.)
6. Why the ECG start sometimes takes 2.6–3.3 s. (Start-stage timing in the
   trace.)
