// 8V: the Device lab's hardware probes, run against the virtual WHOOP MG on a
// virtual clock: the buzz-spacing probe (replies, band events, felt counts) and
// the cued ECG touch probe (cues, packets, analysis), plus their safety bounds.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';

import 'support/ecg_trace.dart';
import 'support/virtual_mg.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 18);

/// A virtual clock: waits move it.
class _Clock {
  DateTime now = _t0;
  int get ms => now.difference(_t0).inMilliseconds;
  Future<void> wait(Duration d) async {
    now = now.add(d);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('HapticProbe', () {
    ({HapticProbe probe, VirtualMgHaptics band, List<String> steps}) rig(
        {List<HapticTrial>? trials, bool Function()? connected}) {
      final clock = _Clock();
      final band = VirtualMgHaptics();
      final steps = <String>[];
      late final HapticProbe probe;
      var playedBefore = 0;
      probe = HapticProbe(
        sendOne: (onReply) async {
          final at = clock.ms + 100; // ~100 ms to write
          final reply = band.command(at);
          onReply(reply, reply != null ? 60 : 3000);
          return true;
        },
        // The wearer feels what the band PLAYED in this trial (a swallowed
        // command is answered "pending" too, but is not played).
        askFelt: (t, i) async {
          final felt = band.played - playedBefore;
          playedBefore = band.played;
          return felt;
        },
        isConnected: connected ?? () => true,
        step: steps.add,
        now: () => clock.now,
        wait: clock.wait,
        trials: trials,
      );
      return (probe: probe, band: band, steps: steps);
    }

    test('the default run stays inside the hardware budget', () {
      final total = HapticProbe.defaultTrials
          .fold<int>(0, (n, t) => n + t.commands);
      expect(total, lessThanOrEqualTo(HapticProbe.maxCommands));
      expect(() => HapticProbe(
            sendOne: (_) async => true,
            askFelt: (_, _) async => null,
            isConnected: () => true,
            trials: List.filled(11, const HapticTrial(300)),
          ), throwsArgumentError);
    });

    test('per trial: commands, writes, replies and the felt count', () async {
      final g = rig();
      final results = await g.probe.run();
      expect(results, hasLength(HapticProbe.defaultTrials.length));
      final at300 = results.firstWhere((r) => r.trial.spacingMs == 300);
      expect(at300.commands.map((c) => c.reply), ['pending', 'pending', 'none'],
          reason: 'the second command is swallowed (answered pending, not '
              'played), the third is ignored (no answer)');
      expect(at300.felt, 1);
      final at1600 = results.firstWhere((r) => r.trial.spacingMs == 1600);
      expect(at1600.felt, 3);
      final at1000 = results.firstWhere((r) => r.trial.spacingMs == 1000);
      expect(at1000.commands.map((c) => c.reply), ['pending', 'pending', 'none'],
          reason: 'writes at 100, 1100, 2100: the 2nd is swallowed (the band '
              'plays until 1600), the 3rd lands in the 1.1 s it then ignores');
      expect(at1000.felt, 1);
      final at1300 = results.firstWhere((r) => r.trial.spacingMs == 1300);
      expect(at1300.felt, 2,
          reason: 'writes at 100, 1400, 2700: the 2nd is swallowed, the 3rd '
              'comes after the deaf window and plays');
      expect(g.steps.where((s) => s.startsWith('Buzz probe, ')),
          hasLength(results.length));
      expect(g.steps.last, 'Buzz probe finished.');
      expect(g.probe.running, isFalse);
    });

    test('band events during a trial are kept with their times', () async {
      final clock = _Clock();
      late final HapticProbe probe;
      probe = HapticProbe(
        sendOne: (_) async {
          probe.onBandEvent(60, clock.now, clock.now);
          return true;
        },
        askFelt: (_, _) async => null,
        isConnected: () => true,
        now: () => clock.now,
        wait: clock.wait,
        trials: const [HapticTrial(300, commands: 2)],
      );
      final r = await probe.run();
      expect(r.single.events.map((e) => e.eventId), [60, 60]);
      expect(r.single.events.last.receivedMs, 300);
      expect(r.single.summary, contains('band events 60 at +0'));
    });

    test('Stop ends the run after the current trial; a lost link ends it too',
        () async {
      final a = rig();
      final run = a.probe.run();
      a.probe.stop();
      final r = await run;
      expect(r.length, lessThanOrEqualTo(1));
      expect(a.steps.last, startsWith('Buzz probe stopped'));
      var connected = true;
      final b = rig(connected: () => connected);
      connected = false;
      expect(await b.probe.run(), isEmpty);
      expect(b.steps.last, 'Buzz probe ended: the band is not connected.');
      expect(b.probe.running, isFalse);
    });
  });

  group('EcgTouchProbe', () {
    test('cues, packets and the analysis on the virtual band', () async {
      final clock = _Clock();
      // The wearer follows the cues: touch on TOUCH, lift on LIFT, ~250 ms
      // late (reaction). Built from the script itself.
      final touches = <(int, int)>[];
      const streamStartMs = 1000; // the first packet, ms after _t0
      var t = 0;
      int? on;
      final leadMs = 0;
      // Steady at the 3rd packet (~2.0 s), plus the 2 s lead-in.
      final cueStart = 2010 + 2000 + leadMs;
      t = cueStart;
      for (final c in EcgTouchProbe.defaultScript) {
        if (c.kind == EcgCueKind.touch) on = t + 250;
        if (c.kind == EcgCueKind.lift && on != null) {
          touches.add((on, t + 250));
          on = null;
        }
        t += c.holdMs;
      }
      final band = VirtualMgEcg(touches: touches, strapAheadOfPhoneMs: 0);
      final packets = band.packets(45);
      final base = packets.first.receivedAt;
      var next = 0;
      final steps = <String>[];
      final cues = <EcgCue?>[];
      var ended = 0;
      late final EcgTouchProbe probe;
      Future<void> wait(Duration d) async {
        clock.now = clock.now.add(d);
        // Deliver every packet that has arrived by now.
        while (next < packets.length &&
            !packets[next]
                .receivedAt
                .difference(base)
                .isNegative &&
            packets[next].receivedAt.difference(base).inMilliseconds +
                    streamStartMs <=
                clock.ms) {
          probe.onFrame(packets[next].r);
          next++;
        }
        await Future<void>.delayed(Duration.zero);
      }

      probe = EcgTouchProbe(
        beginStream: () async => true,
        endStream: () async => ended++,
        isStreamAlive: () => true,
        onCue: cues.add,
        step: steps.add,
        now: () => clock.now,
        wait: wait,
      );
      final lines = await probe.run();
      expect(ended, 1, reason: 'the stream is always stopped');
      expect(cues.whereType<EcgCue>().map((c) => c.kind),
          containsAllInOrder([EcgCueKind.rest, EcgCueKind.touch, EcgCueKind.lift]));
      expect(cues.last, isNull);
      expect(probe.cues, hasLength(EcgTouchProbe.defaultScript.length));
      expect(lines.first, startsWith('ECG touch probe: '));
      final cueLines =
          lines.where((l) => l.startsWith('ECG touch probe cue ')).toList();
      expect(cueLines, isNotEmpty);
      // The first long hold is seen; the quick taps after lifts are not (the
      // virtual sensor is still blind then), and the analysis says so.
      expect(cueLines.first, contains('TOUCH'));
      expect(cueLines.first, contains('seen'));
      expect(cueLines.where((l) => l.contains('not seen')), isNotEmpty);
      expect(steps, containsAll(lines));
    });

    test('a stream that never gets steady ends the probe and stops it',
        () async {
      final clock = _Clock();
      var ended = 0;
      final probe = EcgTouchProbe(
        beginStream: () async => true,
        endStream: () async => ended++,
        isStreamAlive: () => true,
        onCue: (_) {},
        now: () => clock.now,
        wait: clock.wait,
        startTimeout: const Duration(seconds: 2),
      );
      final lines = await probe.run();
      expect(lines.first, contains('no steady stream'));
      expect(ended, 1);
      expect(probe.running, isFalse);
    });

    test('a stream that did not start sends no cues and stops nothing',
        () async {
      var ended = 0;
      final cues = <EcgCue?>[];
      final probe = EcgTouchProbe(
        beginStream: () async => false,
        endStream: () async => ended++,
        isStreamAlive: () => false,
        onCue: cues.add,
        wait: (_) async {},
      );
      expect(await probe.run(), isEmpty);
      expect(ended, 0);
      expect(cues.whereType<EcgCue>(), isEmpty);
    });

    test('the script fits inside the stream limit', () {
      final ms = EcgTouchProbe.defaultScript.fold<int>(0, (n, c) => n + c.holdMs);
      expect(Duration(milliseconds: ms + 2000 + 6000),
          lessThan(EcgTouchProbe.maxStream));
    });
  });

  group('contactRuns', () {
    EcgProbePacket p(int sec, List<int> samples) => EcgProbePacket(
        r17(strapSeconds: sec, samples: samples), _t0);

    test('a single zero (the trace crossing zero) does not split a run', () {
      final s = List<int>.filled(100, 100);
      s[50] = 0;
      expect(contactRuns([p(1000, s)]), hasLength(1));
    });

    test('a 100 ms gap does; runs carry their start sample index', () {
      final s = List<int>.filled(100, 0);
      for (var i = 10; i < 30; i++) {
        s[i] = 5;
      }
      for (var i = 40; i < 60; i++) {
        s[i] = 5;
      }
      final runs = contactRuns([p(1000, s)]);
      expect(runs, hasLength(2));
      expect(runs.map((r) => r.startIndex), [10, 40]);
      // Newest sample at 1000.0 s: sample 10 is at 999.1 s.
      expect(runs.first.startMs, 999100);
      expect(runs.first.endMs, 999300);
    });
  });

  group('HardwareProbeRunner', () {
    HardwareProbeRunner runner(DeviceLabLog lab,
            {bool connected = true, bool mg = true, bool busy = false}) =>
        HardwareProbeRunner(
          lab: lab,
          sendBuzz: (onReply) async {
            onReply('pending', 50);
            return true;
          },
          sendPattern: (effects, loop, onReply) async {
            onReply('pending', 50);
            return true;
          },
          isConnected: () => connected,
          ecgSupported: () => mg,
          ecgBusy: () => busy,
          beginEcg: () async => false,
          endEcg: () async {},
          isEcgAlive: () => false,
        );

    test('refuses with a reason instead of starting', () async {
      final lab = DeviceLabLog();
      final off = runner(lab, connected: false);
      expect(off.canRunBuzz, isFalse);
      await off.runBuzz();
      expect(off.note, 'Connect the band first.');
      final noEcg = runner(lab, mg: false);
      await noEcg.runEcg();
      expect(noEcg.note, 'This band has no ECG sensor.');
      final busy = runner(lab, busy: true);
      await busy.runEcg();
      expect(busy.note, contains('in use'));
      expect(lab.sessionSummaries, isEmpty);
    });

    test('a buzz run asks after every trial and logs a session', () async {
      final lab = DeviceLabLog();
      final r = runner(lab);
      var asked = 0;
      r.addListener(() {
        if (r.question != null) {
          asked++;
          r.answer(asked == 1 ? 3 : null);
        }
      });
      // The real waits are short enough here: 8 trials, each a few seconds.
      // Stop after the first question to keep the test fast.
      final run = r.runBuzz();
      expect(r.running, ProbeKind.buzz);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      r.stop();
      await run;
      expect(r.running, isNull);
      expect(lab.sessionSummaries.single, startsWith('Buzz probe | '));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('an ECG run that cannot start the stream ends cleanly', () async {
      final lab = DeviceLabLog();
      final r = runner(lab);
      await r.runEcg();
      expect(r.running, isNull);
      expect(r.cue, isNull);
      expect(lab.steps.join('\n'), contains('the stream did not start'));
      expect(lab.sessionSummaries.single, startsWith('ECG touch probe | '));
    });
  });
}
