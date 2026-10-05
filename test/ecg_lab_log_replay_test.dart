// 8AK A (red): the lab-trace replay built from the 2026-10-04 device log.
//
// The log (edge.research/ecg-bad-connection-2026-10-04.log) has five ECG
// gestures on a WHOOP MG. Four ended in the failure buzz ("ECG failed
// (start_failed): one long buzz", then "Fallback: the count is 2"): the
// stream start was refused ("prepare answered (refused)" ~5.1 s after the
// guard was set), so no packet ever came. The fifth started normally and
// counted 5 (three follow-ups and the confirm). Support/ak_log_timeline.dart
// rebuilds that sequence from the log's own timestamps and packet summaries.
//
// ASSUMED BEHAVIOUR (lib/gestures/ecg_tap_session.dart, EcgTapSession):
//   * A stream start that is refused, throws or times out is retried ONCE
//     inside the same gesture BEFORE the double-tap fallback is taken, also
//     with `fallbackToDoubleTap` on (today only with it off). The retry runs
//     the same `beginStream` (never a different or dangerous command: the
//     session only ever calls its injected begin/end). It starts the stream
//     again; it does not repeat the start cue. A second refusal ends as
//     today: one failure cue, count 2 (fallback), flags reset.
//   * Everything after the stream is up is unchanged (the good run).
//
// Failure mode today: with the fallback on a refused start ends the gesture
// at once ("began 1"), so the replay that then lets the second start succeed
// ends in the failure cue and a count of 2 instead of 5.

import 'package:flutter_test/flutter_test.dart';

import 'support/ecg_tap_session_failure_rig.dart';
import 'support/ecg_bad_connection_log_timeline.dart';

void main() {
  group('the log\'s failed gestures: the stream start was refused', () {
    test('a refused start is retried once; the second attempt starts the '
        'stream and the gesture counts 5 (no failure buzz)', () async {
      // The log's 02:05:23 gesture refused its start; the 02:07:04 one (same
      // settings, same band) did not. A retry gives the gesture the chance
      // the second one had.
      final r = logRig(begins: const [false, true], reportFailures: true);
      await r.session.start(logTap());
      expect(r.began, 2, reason: 'one retry of the stream start');
      await feedGoodRun(r);
      expect(r.results, [(5, null)]);
      expect(r.names, ['start', 'follow', 'follow', 'follow', 'confirm'],
          reason: 'one start cue (the retry does not repeat it), no failure');
      expect(r.failures, isEmpty,
          reason: 'a failure that the retry cured is not a failure');
      expect(r.steps, contains(contains('trying the ECG once more')));
      expect(r.session.active, isFalse);
    });

    test('the same when the first start throws (the radio hiccuped)',
        () async {
      final r = logRig(begins: [StateError('radio went away'), true]);
      await r.session.start(logTap());
      await feedGoodRun(r);
      expect(r.results, [(5, null)]);
      expect(r.names.where((n) => n == 'fail'), isEmpty);
    });

    test('refused twice (the retry is bounded): count 2 by fallback and ONE '
        'failure cue, nothing left running', () async {
      final r = logRig(begins: const [false, false], reportFailures: true);
      await r.session.start(logTap());
      expect(r.began, 2, reason: 'one retry, not a loop');
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.names, ['start', 'fail']);
      expect(r.failures, ['start_failed']);
      expect(r.session.active, isFalse);
      expect(r.records, hasLength(1), reason: 'the interval is still written');
    });

    test('a gesture after a refused-twice one starts normally (no flag left '
        'set)', () async {
      final r = logRig(begins: const [false, false, true]);
      await r.session.start(logTap());
      expect(r.session.active, isFalse);
      await r.session.start(akDoubleTap(sec: 30));
      expect(r.session.active, isTrue);
      expect(r.began, 3, reason: 'the second gesture got its own start');
    });
  });

  group('the log\'s good run (regression guard: passes today)', () {
    test('its packets count 5: window at ...229499, follow-ups at the log\'s '
        'sample times, one confirm', () async {
      final r = logRig();
      await r.session.start(logTap());
      await feedGoodRun(r);
      expect(r.results, [(5, null)]);
      expect(r.names, ['start', 'follow', 'follow', 'follow', 'confirm']);
      expect(
          r.steps,
          contains(startsWith('Touch window open at sample time '
              '1791101229499 ms, 2500 ms after the first sample')));
      final asked = [
        for (final s in r.steps)
          if (s.startsWith('Follow-up buzz requested at sample time '))
            s.replaceAll(RegExp(r'[^0-9]'), ''),
      ];
      expect(asked, hasLength(3));
    });

    test('the stream is called steady by packet 4, once, as in the log',
        () async {
      final r = logRig();
      await r.session.start(logTap());
      await feedGoodRun(r, count: 4);
      expect(r.steps.where((s) => s.startsWith('Stream is steady')), hasLength(1));
    });
  });
}
