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
- **L3**: 2026-10-02 20:40, the 8V hardware probes (buzz probe and ECG touch
  probe) plus count-buzz gestures, with the band's replies and events, the
  wearer's counts of what they felt, and the cue-to-contact latencies. It
  replaces two L1/L2 readings below (marked "superseded"). Not stored as a
  fixture; the numbers below are read from it.
- **L4**: 2026-10-02 22:27–22:36, the 8W pattern probe (32 tests) with the band's
  events, replies and the wearer's counts. The counts were the old coarse input
  (how many buzzes, how many groups), so findings that rest on them are marked
  "rough". Not stored as a fixture; the numbers below are read from it.

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
| A lift shows as zeros almost at once (≤ ~0.3 s after the cue, reaction time included). | High | L2 18:17:57: buzz started at phone 18:18:04.33 (event 60), zeros from 04.55. L3: every lift in the probe showed within ~0.3 s. |
| A touch becomes visible **~1.9 s after the finger lands** (2.2–2.4 s after the cue, reaction included), **whatever the lift before it lasted** (0.4 to 2.5 s in L3). | High | L3 touch probe, every cue that showed. Also fits L2's two re-touches (1.96 s and 2.16 s after the lift, with the finger back almost at once). |
| A touch starts on a 100 ms grid: its first non-zero sample has index 6 mod 10 within its packet (6, 16, 46, 56, 66 seen). So the band checks for contact every 100 ms, and reports it once a finger has been there ~1.9 s. | Medium | L3 contact-run start positions. |
| 300 ms taps never showed; a touch that lifts before the ~1.9 s check is invisible. | High | L3 probe, last three cues, every time. |
| The band's presence bit is **useless for taps**: on before any touch and never off. | High | L3: every packet line. |
| **Superseded (L2 reading):** "the band checks once per packet and holds a returning finger back for `hold` after a lift, 1.16–1.96 s (1.5 s in the model)." L3 lifts of 0.4 s and 2.5 s showed with the same ~1.9 s delay from landing, so there is no hold that depends on the lift. The L2 cases were a touch latency seen right after a short lift. | Superseded | L3 vs L2 18:19:10, 18:19:41. |
| Code today: `sensorReacquire` (1.5 s) is still added to the window after a lift. It stays as a lower bound; with the touch latency it is the wearer's landing time, not the lift, that the sensor needs ~1.9 s after. Not re-tuned in 8W (see open questions). | Rule | `ecg_tap_session.dart`; replay of L2 18:19:10 counts tap 4 with it, 3 without. |
| While touching, 96–100 of 100 samples are non-zero (the trace crosses zero). | High | L1, L2. |
| Each packet also carries the band's own electrode **presence** bit (flags bit 3, debounced by the band), the HeartKey S2 state, progress, quality and an unreadable mask. These were not logged before 8V; every packet line now shows them. | Protocol | `openstrap_protocol` `labrador.dart` |
| The ECG **reading** state machine ends a capture after 3 contact losses, and sends an explicit RESTART when the S2 state drops with presence on (and drops packets while the restart runs). A gesture lifts its finger by design, so with `persist: false` neither happens; both are logged instead. | Rule | `ecg_controller.dart`, `ecg_policy.dart` |

## Haptics

Every buzz command the app sends is `RUN_HAPTIC_PATTERN_MAVERICK` (0x13) with
the body `01 2f 98 00 00 00 00 00 00 00 00 01` (`AlarmPayloads.gen5MaverickBuzz`):
revision 0x01, eight waveform-effect slots (0 = idle; here effect 47 then 152),
a u16 little-endian loop control per effect, and an overall loop byte. That
layout is the protocol notes' reading; what the loop bytes mean is not confirmed
(see open questions).

| Finding | Confidence | Evidence |
|---|---|---|
| **One command is felt as one "bzz-bzz"**, not as one buzz and not as a count. | High | L3, wearer's counts for every played command. |
| Band events 60 (HAPTICS_FIRED) arrive ~15 ms after a command that plays; 100 (HAPTICS_TERMINATED) 1.08–1.50 s after the 60. | High | L3 events against command writes. |
| A command written **while the band plays** (before its 100) is answered "pending" and **not played** (no 60). | High | L3. |
| After such a swallowed command the band **ignores the next command entirely** (no reply, not played) for about 1.0–1.27 s: 0.95 s later it was ignored, 1.27 s later it played. | Medium (few cases near the edge) | L3. |
| A command written after the 100 always plays, even 0.4 s after it. | High | L3. |
| The busy window is therefore the play time itself (60 to 100, 1.1–1.5 s), not a fixed time after the command. | High | L3. |
| **Superseded (L1/L2):** "each pulse of a multi-pulse buzz is its own command, two pulses 300 ms apart are felt as two." L1 and L2 took the replies and the wearer's counts as two pulses played; L3, with the 60 and 100 events beside each command, shows that a second command inside the play was swallowed. | Superseded | L3 shows the second command's reply is "pending" with no event 60. |
| **Superseded (L1/L2):** "the band takes one more command while busy and drops the rest; busy time ~1.25-2.0 s from the first write." Replaced by the play window plus ignore window above; the missing reply of the 3rd command in L2 fits the ignore window after a swallowed 2nd. | Superseded | L3. |
| 113 is the stream start (time equal to the first packet's strap time); 114 follows the stream stop. | Medium | L1, L2. |
| Consequence: a count of N is **N commands, one per pulse** (`maxPulsesPerBurst` = 1), each at least `buzzQuietGap` (1.8 s) after the previous write, which is past the longest play (1.5 s) and the ignore window. Pacing on event 100 instead is not used in gestures; the pattern probe's "event-paced" style tries it. | Rule | `ecg_tap_session.dart`; the virtual band swallows and ignores as above. |

### Pattern probe findings (L4)

Event envelope = event 60 to event 100, as the phone received them.

| Finding | Confidence | Evidence |
|---|---|---|
| Effect envelopes: **47 alone 0.77–1.03 s**, felt as one buzz; **14 alone 0.53–0.91 s**, one buzz; **1 alone 0.22–0.61 s**, one short buzz or click; the **pair 47+152 1.07–1.36 s**, felt as two. | Medium (felt counts rough) | L4. |
| **152 is felt as a buzz, not as a silent pause**: 47,152,47 felt as 3; 47,152,47,152 as 4; (47,152)x3 as 6; x,152,x,152,x as 5 for 47, 14 and 1. | Medium (rough counts, consistent over every waveform) | L4. |
| **The overall loop byte is not a whole-pattern repeat.** Pair with loop 2 / 3 played 1.96 s / 2.0 s (a whole repeat would be about 2.6 s / 3.9 s) and was felt as 3 / 4; single effects with loop 2–3 played barely longer than loop 1 and were felt as 1–2. | Medium | L4. |
| Separate commands all played when each was written **after the previous one's event 100** (even 0.03–0.25 s after). One written 20 ms before the 100 was dropped (the buzz probe's 1600 ms trial). So: send after the 100, never on a fixed timer shorter than the longest envelope. | High | L4. |
| **The band delivers old 60/100 events late, in bursts** (22:36:31: about 25 events 17–80 s old). A probe must ignore events that are not live, or it releases commands on stale ones; test 21's event-paced commands went out on such events. | High | L4. |

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

Under Devices → your band → Device lab → Hardware probes. All three start only
from their button, stop at once on Stop or when you leave the screen, and write
everything into the lab log ("Copy all logs").

- **Buzz probe.** Eight groups of three single buzzes, 200 ms to 1600 ms apart
  (at most 30 buzzes per run, a 2 s rest after each group). After each group
  it asks how many bzz-bzz you felt (one command plays as one). The log line per
  group has, for each command, when it was asked for and written, the band's
  reply (or `none`), and the band events seen, in ms from the group's start.
- **ECG touch probe.** Streams for at most 60 s. After the sensor settles the
  screen (and the phone's own vibration) cues: keep off, then touch-and-hold /
  lift with lifts of 0.4, 0.8, 1.5, 2.5 and 2 s, then three quick taps. The
  log ends with every contact run (and where in its packet it started), every
  change of the band's presence bit, and for each cue how long after it the
  sensor showed the change. Cue times are mapped onto the strap clock through
  the least-delayed packet, so each latency includes your reaction time and the
  best packet's own latency (~0.15 s).
- **Pattern probe** (8W, MG only; a transcriber since 8Y). The button opens a
  screen. 40 tests: 32 in the 8W cycle (4 waveforms x 4 ways of sending x 2
  counts, 2 and 3, cycling so an early stop has still tried every waveform and
  way), then 8 gap tests.
  - Waveforms (effect ids in the command's slots): the band's pair 47 + 152,
    effect 47 alone, effect 14, effect 1.
  - Ways of sending: *paced* (separate commands, each 1.8 s after the previous
    write), *event-paced* (separate commands, each 100 ms after the band's live
    event 100, or 2.5 s after the previous write if none came), *repeat* (one
    command, overall loop = the count), *listed* (one command listing the
    waveform count times, with a 152 slot between copies of a single effect).
  - Gap tests 33–40: *delayed*, two separate commands of effect 14 then 47
    (alternating), the second 0, 300, 700 or 1200 ms after the live event 100
    of the first (2.5 s if none came); order (14,0) (47,0) (14,300) (47,300)
    (14,700) (47,700) (14,1200) (47,1200).
  - **Play** sends the test on screen, as often as you like. Before each play it
    waits for the band to finish the last one (a live event 100 after the last
    write, or 4 s). After the last write it waits for a live 100 (4 s at most).
    Only live events count: an event counts if it happened no earlier than 500 ms
    before the play started and reached the phone within 2 s.
  - **Transcribing.** You tap what you felt like morse: buttons of length 1–4,
    entries alternating buzz, gap, buzz, gap (the first is a buzz; the footer
    buttons read "Buzz 1–4" with solid bars or "Gap 1–4" with hollow bars for the
    entry they write). The entries are a wheel you scroll to go back and forward
    and edit any of them. Up to two renditions (A and B) per test, because the
    band may not play a test the same way twice; previous / next moves between
    tests and Play replays it there. Gap entries are the felt length of the
    silence, so a later fit can map felt units to milliseconds.
  - Leaving the screen writes one line per transcribed or played test:
    `Pattern probe heard 5/40, <test>: A = buzz 2, gap 1, buzz 4 (B2 G1 B4);
    B = —; played 3×.` Each play also logs its payload in hex, writes, replies,
    the live band events with their times, and `silences: <ms>, …` (each live 60
    minus the live 100 before it) and `buzzes: <ms>, …` (each 100 minus its 60).
  - What it answers: what the loop byte does, whether 152 is a buzz, how long
    each effect is felt, and the data to build an encoder from a tapped rhythm
    to a band command (felt buzz and gap units against real envelopes and
    delays).
  - **Notes, rests and tempo (8Z).** Entries are now typed: a note (the band
    buzzed) or a rest, each 1–4 units, with a Note/Rest toggle that flips after
    every tap (override it for two notes or two rests in a row). One unit is an
    eighth, so lengths 1–4 are an eighth, quarter, dotted quarter and half, and a
    4/4 bar is 8 units. The page starts at 250 ms per unit (effect 1 is felt for
    about 0.22–0.6 s, 1–2 units; effect 14 about 2–3 units, effect 47 about 3–4,
    each half of the 47 + 152 pair about 2). With "Dynamic tempo" on, ms per unit is fitted from
    the plays: for each test, the span from the first live event 60 to the last
    live event 100 divided by the units of your transcription up to its last note,
    then the median over tests (100–800 ms, needs 2 tests). The fit goes in
    the log: `Pattern probe tempo: 1 unit ≈ N ms`. The Bluetooth lead (first write
    to the first live 60, median over plays, 300 ms until measured) delays the
    march's start. A replay marches a playhead through your entries at that tempo from the first
    write plus the lead, so a mismatch between what you wrote and what the band
    plays shows up as the playhead drifting from what you feel.
  - **16th notes and dynamics (8AA).** The unit is now a sixteenth, so the lengths
    are 1, 2, 4, 6 and 8 units (16th, eighth, quarter, dotted quarter, half), a 4/4
    bar is 16 units, and the page starts at 125 ms per unit (the old 250 ms eighth;
    the fit is clamped to 50–400 ms and the log says `1 sixteenth ≈ N ms`). Every
    note also gets a dynamic, ff, mf, mp or pp, which is how strongly you felt that
    buzz, loudest to softest. It is your own judgement per note, not a setting sent
    to the band; the point is to see whether the same effect feels different in
    different places. Notes in the log read `N<length><dynamic>` and rests
    `R<length>`: `N4mf R2 N1ff` is a quarter note at mf, an eighth rest, then a 16th
    note at ff.
  - **Dotted lengths, count-in, end screen, rolling limit (8AB).** A Dot button
    beside the 16th, eighth, quarter and half buttons makes the next entry 3/2 as
    long (one shot; a 16th cannot be dotted), so the lengths are now 1, 2, 3, 4, 6,
    8 and 12 units and the log reads `N3mf`, `R6`, `N12ff` (dotted eighth, dotted
    quarter, dotted half). The metronome is off until Play; Play gives a one-measure
    count-in (16 steps), asks the band one measured Bluetooth lead before the next
    downbeat so the buzz starts on it, and marches the playhead from that downbeat.
    The metronome keeps going until the play has finished and the march has ended,
    plus one padding measure to the bar line, then goes idle. Finish (or going back)
    closes the probe, which writes the heard lines and the tempo line, and shows an
    end screen with tests transcribed, plays, the tempo, the measured lead, "Copy all
    logs" (the same text as the Device lab's button, taken after the close so the
    heard lines are in it) and Done. The probe no longer stops at 160 commands a
    session. The band now gets at most 30 commands in any 2 minutes, counted over all
    plays and kept when the screen is closed and reopened; a play that would go over
    is refused with `Pattern probe: resting the band; ready in N s (30 commands per
    2 minutes).` and the page says "Band resting, ready in N s" under Play. (In 8Y-8AA
    the old cap refused every play from test 20 on, with nothing on screen to say
    so.) A small display shows "N of 30 left" and "next in m:ss", red under 5 left;
    it is blurred until tapped so its countdown does not compete with the metronome.

Safety and hardware health: the buzz and pattern probes send only the band's
own buzz command (RUN_HAPTIC_PATTERN_MAVERICK), through the alert dispatcher
like every other buzz. Hard bounds: the pattern probe writes at most 30
commands in any 2 minutes (`PatternProbe.maxCommandsPerWindow` and
`commandWindow`, counted over all plays; a play that would go over is refused
until enough of the window has passed), each pattern has 1-8 effects with ids 1-255, the
loop is capped at 3, every play waits for the band to finish the last one, and a
play where nothing could be written is not counted. The pattern probe is
refused on a band that is not an MG. The ECG stream is capped and always
stopped, also on errors. No sample leaves RAM unless you copy the log
(invariant 14). Dangerous opcodes (invariant 15) are not involved.

## Vocabulary (L6)

The L6 run is the pattern probe at a fixed tempo (one sixteenth = 125 ms), all 40
tests transcribed. The log is `docs/hardware/logs/2026-10-03-pattern-probe-L6.txt`;
its `Pattern probe heard N/40 ...` lines are the OUTPUT set, read by
`parseHeardLines` (`lib/haptics/heard_log.dart`). The 40 tests are the stable
INPUT set `whoop-mg-pattern-v1` (`kWhoopMgPatternProbeSet`): their numbers are
indices + 1 and never move, a test pins their descriptions, and the probe writes
`Pattern probe set: whoop-mg-pattern-v1` once when it opens. The measured
vocabulary is the profile `whoop-5.0-mg` (`HapticDeviceProfile.whoopMg`, version 1,
`lib/haptics/haptic_profile.dart`); a test reads the log and checks the table
against it.

**Dynamics.** The probe has six, loudest to softest: ff, f, mf, mp, p, pp (codes
`N4f`, `N2p`). The wearer's reading of the loudest effects: 14 is f, while 47 is ff;
there are grades between for p and pp. A limited 4/4 system of notes, rests and
these dynamics expresses most of what the band plays.

**Phrases.** One phrase is one band command and how it is felt, as the shortest
and longest rendition heard (equal when only one was). Codes are `N<length><dynamic>`
and `R<length>` in sixteenths. Multi-command tests were split at the rest between
commands.

| Phrase | Effects | Loop | Shortest | Longest | Tests |
|---|---|---|---|---|---|
| `buzz47` | 47 | 1 | N4ff | N4ff | 2, 6, 18, 22, 34, 36, 38, 40 |
| `buzz14` | 14 | 1 | N3f | N4f | 3, 7, 19, 23, 33, 35, 37, 39 |
| `click1` | 1 | 1 | N1mp N1mp | N1mp N1mp | 4, 8, 20 |
| `pair` | 47, 152 | 1 | N2mf R2 N2mf | N3mf R1 N3mf | 1, 5, 17, 21 |
| `buzz47x2` | 47 | 2 | N6ff | N6ff | 10 |
| `buzz47x3` | 47 | 3 | N8ff | N8ff | 26 |
| `buzz14x2` | 14 | 2 | N6ff | N6ff | 11 |
| `buzz14x3` | 14 | 3 | N8ff | N8ff | 27 |
| `click1x2` | 1 | 2 | N1mf N1mf N1mf | same | 12 |
| `click1x3` | 1 | 3 | N1mf N1mf N1mf | same | 28 |
| `pairx2` | 47, 152 | 2 | N2mf R2 N2mf R2 N2mf | same | 9 |
| `pairx3` | 47, 152 | 3 | N3mf R1 N3mf R1 N3mf R1 N3mf | same | 25 |
| `pair2` | 47, 152, 47, 152 | 1 | N3ff R1 N3ff R1 N3ff R1 N3ff | same | 13 |
| `pair3` | 47, 152 x3 | 1 | N2mf R2, six notes | same | 29 |
| `arc47` | 47, 152, 47 | 1 | N2ff R1 N4ff R3 N3mf | same | 14 |
| `arc14` | 14, 152, 14 | 1 | N2mf R1 N4ff R1 N3mf | same | 15 |
| `arc1` | 1, 152, 1 | 1 | N1mp R1 N1pp N1pp R2 N2mp | same | 16 |
| `arc47x3` | 47, 152, 47, 152, 47 | 1 | N2mf R2 N2mf R2 N4ff R2 N2mf R2 N2mf | same | 30 |
| `arc14x3` | 14, 152, 14, 152, 14 | 1 | N2mf R1 N2mf R2 N4ff R2 N2mf R1 N2mf | same | 31 |
| `arc1x3` | 1, 152, 1, 152, 1 | 1 | N2mf R1 N1mp R1 N1mp N1mp R1 N2mp R1 N2mf | same | 32 |
| `click1soft` | 1 | 1 | N1pp N1pp | N1pp N1pp | 24 (unstable) |

**Arcs.** In the three-command-slot tests (the `arc` rows) a middle slot is a 152
between two copies of the effect. The wearer heard the nearby commands spike the
amplitude: the notes rise from mf to ff in the middle slot and fall back to mf
(`N2mf R1 N4ff R1 N3mf`). They are kept as measured, so the compiler can use
them as a loud accent.

**Gaps.** Writing the next command after the band's live event 100 gives a rest
whose felt length depends on the write delay. Gap tests 33 to 40 and the second
command of the pair tests give:

| Write delay after 100 | Felt rest (sixteenths) | Tests | Stable |
|---|---|---|---|
| 0 ms | 3 to 4 | 33, 34 | yes |
| 100 ms | 3 to 4 | 6, 7A, 8, 22, 23 | yes |
| 100 ms | 1 to 6 | 5, 7B, 21, 24 | no (the pair and the unstable test spread wide) |
| 300 ms | 4 to 6 | 35, 36 | yes |
| 700 ms | 6 to 8 | 37, 38 | yes |
| 1200 ms | 12 to 14 | 39, 40 | yes |

A rest longer than 14 sixteenths is written as 1200 ms + (units - 13) x 125 ms
("extrapolated"): waiting longer only lengthens the silence, so it is allowed in
both modes and counts as stable.

**Unstable probe rounds.** The band does not always play a test the same way, and
some tests were very variable. A test is unstable when the wearer marked it so
(the page's Unstable toggle: rendition A is the shortest, B the longest, order does
not matter to the data) or, in a legacy log, when a rendition ends with `R1 R2 R4`
(a sixteenth, an eighth and a quarter rest) as a flag; those three rests are
stripped before use. Unstable rows (`click1soft`, the 100 ms gap with the 1 to 6
spread) are left out of the compiler's rules by default and used only with the
"Extended haptics opset, timings may vary unexpectedly" toggle (off by default),
which a rule stores as `extended`. The log line reads `Pattern probe heard 24/40,
..., unstable (A and B are the shortest and longest): A = ...; B = ...; played N×.`
The probe is meant to grow to other devices; the WHOOP 5.0 MG is the only one
measured.

## From taps to band commands

A rhythm the wearer taps, or notes they write, reaches the band as measured
commands, never as a guessed timing.

1. **Taps to notes.** `notesFromTaps` turns each press into a note of the allowed
   length nearest its hold (a quick tap is a sixteenth) at mf, and each release
   gap into rests (largest allowed length first). Notes are the intermediate
   representation: a saved rule stores them (`notes`, as a transcript code such as
   `N4mf R2 N1mf`) with the `profileId` and `profileVersion` it was made for, and
   keeps the taps.
2. **The compiler.** `compile` picks band commands (phrases) and write delays
   (gaps) from the profile so what is felt lands nearest the notes. A dynamic
   program over sixteenths; a placement costs 4 per cell that disagrees about note
   versus rest, plus the dynamic weight times the loudness distance (index
   distance in ff, f, mf, mp, p, pp) where both are notes; taps carry no loudness,
   so their weight is 0. A **penalty** of 2 per command beyond the first prefers
   one command when it is nearly as good. Ties go to fewer commands, then stable
   parts only, then lower delay. `exact` means no cell or dynamic mismatch,
   whatever the penalty. Without the extended opset only stable phrases and gaps
   are used.
3. **The 10 s cap.** A plan whose longest felt length is over `kMaxHapticRuntime`
   (10 s) is not produced; the editor says "Too long for the band: keep it under 10
   seconds." and disables Save. (8AD adds an override.)
4. **Pre-bake.** On Save the editor stores the compiled plan with the rule
   (`bakedSteps`: effects, loop, delay, JSON key `plan`), from the same plan it
   showed. Delivery plays the baked commands when the profile id matches, so a
   later vocabulary update never changes a saved rule. Without a baked plan it
   compiles the notes, then the taps; with no profile (a 4.0) or when nothing
   compiles it plays today's per-tap buzz.
5. **Delivery.** For each command after the first, the player waits for the previous
   command's live event 100 (up to its longest span + 1.5 s; a timeout carries on),
   then the step's delay, then writes. A band event counts only when it is live.
6. **The global band queue.** Every band haptic job (a rule's rhythm, a single buzz,
   a tap ack, a preview, the ECG count buzzes, the notification relay) goes through
   one queue (`BandHapticQueue`), first in first out, one at a time. A job starts
   when the previous one has finished (its last command's event 100, or a timeout)
   and the shared ledger allows its commands: at most 30 commands in any 2 minutes
   (`BandCommandLedger`), the same ledger the pattern probe counts its writes in,
   so the lab and real alerts cannot go over it together. A job that cannot start
   within 15 s of being queued is dropped as rejected with nothing written and its
   alert claim given back; once started, its transport timeout counts from the
   start. The log says `Band queue: waiting for the band (N ahead)` and `Band
   queue: resting, ready in N s`.

## Patterns and safety

Settings > The band > Haptics (8AD) is where buzz patterns are kept and where the band's
limits are shown.

- **Named patterns.** A pattern is a saved rhythm with a name (1 to 40 characters, unique
  without regard to case) and a stable id, stored under `haptic_patterns_v1`. An alert or a
  relay channel that picks one keeps a copy of it with the pattern's id, so playing never
  looks the store up. Replacing, renaming or deleting a pattern goes through
  `propagatePattern`, which rewrites the copies in the alert rules, the relay channels and
  the per-app sequences; a deleted pattern's copies keep their rhythm and lose the id.
- **Writing notes.** On an MG the notes editor writes a pattern as notes and rests (16th,
  eighth, quarter, half, a dot, six dynamics), shows what the band will play for them, and
  plays exactly what is on the page. A 4.0 has no measured vocabulary: it has tap patterns
  only.
- **Allow long sequences.** Off by default. The 10 s runtime cap (see "From taps to band
  commands") is lifted for the tap sheet, the editor and delivery when the wearer turns it
  on, after a confirmation: "May cause harm to your device. Use at your own risk." Turning
  it off needs none. The 8-command plan cap, the one band queue and the 30 commands per 2
  minutes still apply, and the Haptics screen reads out how many commands are left and how
  many jobs are waiting.
- **Test and Calibration.** "Buzz the band" is the same delivery as the device page's Tools
  row. The Device lab link appears in developer mode only.
- **More logs.** `buildProfileFromLogs` merges every heard log in `docs/hardware/logs` into
  the vocabulary (shortest and longest felt length per phrase; unstable if any log says so;
  the version goes up when anything changed), and `tool/build_haptic_vocab.dart` prints the
  diff against the table in code. The probe's "Tap what you felt" button fills a rendition
  from a tapped rhythm.

## Replaying off the band

The lab keeps the last ~6 minutes of ECG packets (raw samples and status
bytes). "Copy all logs" ends with an `ECG packets` section, one `r17v1` line
per packet. Save it under `test/fixtures/ecg_traces/` and:

```dart
final trace = Trace.load('test/fixtures/ecg_traces/<file>.txt');
final r = await replayTrace(trace.of('tap 18:19:10.695'),
    thresholds: thresholdsOf('start 500 ms, gap 200 ms, confirm 1000 ms'));
```

### Contact rule (8X)

A gesture no longer reads "contact" as "sample is not zero". The session asks
`ecgContactMask` (`lib/gestures/ecg_contact.dart`): it cuts each packet into 50 ms
blocks (5 samples) and a block is contact when the signal moves inside it (any
sample differs from the one before). A flat block, zeros or any constant, is no
contact. A run of contact blocks shorter than 100 ms is dropped as a glitch,
except a run at the start or end of a packet, which may continue across the
packet boundary. The extra-sensitive switch works on this mask. The ECG touch
probe still measures the raw non-zero rule (it measures the sensor).

Watch for: a saturated or flat-at-max trace (a sensor pinned at its limit, or a
constant offset) has no movement, so this rule reads it as no contact, where the
old non-zero rule read it as contact. No logged session shows one; if a lab
run does, the rule needs another test.

`test/hardware/lab_trace_replay_test.dart` replays L2 both ways. To try an
idea without any recording, script a wearer on the virtual band
(`test/hardware/virtual_mg_test.dart`): finger-on intervals in, packets with
receipt times out, and a haptic model that plays, swallows and ignores commands
as L3 shows.

## Open questions (what the next lab run should answer)

1. What the loop bytes mean. L4 says the overall loop (last body byte) is not a
   whole-pattern repeat; what is it, and what are the two per-effect loop bytes?
   (Pattern probe: *repeat* tests, now transcribed.) Do 3 plays of one command come as three bzz-bzz or one
   longer one, and does the band's busy window grow with it?
2. What effect 152 is. L4 says it is felt as a buzz, not a silent pause; is it a
   short click, or a weak buzz? (Pattern probe: *listed* tests, transcribed.)
3. Which effect ids exist and feel different: only 47, 152, 14 and 1 are tried.
   Where does one effect end and the next begin in the band's own pair?
4. Can one command play two or three bzz-bzz? If *listed* or *repeat* does it,
   `maxPulsesPerBurst` can go up and a count is felt sooner. (Pattern probe.)
5. Does pacing on event 100 (100 ms after it) always play? (Pattern probe:
   *event-paced*; gestures still use the fixed 1.8 s gap.)
6. The touch window after a lift: the sensor needs ~1.9 s after the finger
   lands, and the code still adds a fixed 1.5 s after the lift. Should the
   window open on the lift and close ~1.9 s + confirm after the *earliest
   possible* landing, and what does that do to fast taps? Taps shorter than
   ~1.9 s cannot be seen at all, so a "tap" gesture over ECG has a floor.
7. Why the ECG start sometimes takes 2.6-3.3 s. (Start-stage timing in the
   trace.)
8. Does the band keep streaming without the reading's RESTART? (Every gesture;
   the trace says "a reading would send RESTART here" when it would have.)
9. What gap the band inserts between effect slots, and how a felt gap length
   (units 1–4) maps to milliseconds. (Pattern probe: the 8 *delayed* gap tests
   and the `silences:` of every play.)
10. Can a tapped rhythm be encoded as a band command? The transcriptions of
    tests 1–40 (renditions A and B) against the real envelopes and delays are
    the data for it.
