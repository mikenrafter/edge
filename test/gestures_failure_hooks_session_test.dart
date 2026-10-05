// 8AK D (red): the ECG session reports a failed gesture, so the failure
// record has something to store. (The dispatcher half is in
// d_failure_hooks_dispatcher_test.dart.)
//
// ASSUMED API:
//   * EcgTapSession `void Function(StrapEvent tap, String reason)? onFailed`
//     (see support/ak_ecg_rig.dart): once per failed ECG gesture, with the
//     abandon reason (start_failed, no_stream, link_lost, stalled,
//     sample_gap), also when the double-tap fallback then runs the double-tap
//     action. Not for a gesture that counted, not for an attempt the start
//     retry cured. `tap.identity` is the gesture's id.
//   * AppState wires this and the dispatcher's to its `gestureFailures` store
//     with the relevant lab log text (test/gesture_controller_test.dart).
//
// Failure mode today: the callback does not exist (the rig drops it), so no
// failure is ever reported.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';

import 'support/ecg_tap_session_failure_rig.dart';

void main() {
  group('the ECG session reports a failed gesture once', () {
    test('a stream start refused twice: start_failed, with the tap', () async {
      final r = AkEcgRig(begins: const [false, false], reportFailures: true);
      await r.tap();
      expect(r.failures, ['start_failed']);
      expect(r.failureTaps.single.identity, akDoubleTap().identity);
      expect(r.results, [(2, 'fallback: start_failed')],
          reason: 'the fallback still runs the double-tap action');
    });

    test('the same with the fallback off: abandoned, still reported once',
        () async {
      final r = AkEcgRig(
        begins: const [false, false],
        reportFailures: true,
        thresholds: EcgTapThresholds(fallbackToDoubleTap: false),
      );
      try {
        await r.tap(); // with the fallback off a failed start throws
      } catch (_) {}
      expect(r.failures, ['start_failed']);
      expect(r.results, [(null, 'start_failed')]);
    });

    test('link_lost before the window opened', () async {
      final r = AkEcgRig(reportFailures: true);
      await r.tap();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.failures, ['link_lost']);
    });

    test('no_stream: no steady stream 20 s after the command', () async {
      final r = AkEcgRig(reportFailures: true);
      await r.tap();
      r.now = kAkT0.add(const Duration(seconds: 21));
      r.session.poll();
      await r.settle();
      expect(r.failures, ['no_stream']);
    });

    test('stalled after the window opened', () async {
      final r = AkEcgRig(reportFailures: true);
      await r.tap();
      await r.steady();
      r.now = r.now.add(const Duration(seconds: 4));
      r.session.poll();
      await r.settle();
      expect(r.failures, ['stalled']);
    });

    test('a failure after a touch was counted is reported with its reason, '
        'not as a fallback', () async {
      final r = AkEcgRig(max: 5, reportFailures: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.failures, ['link_lost']);
      expect(r.results, [(null, 'link_lost')]);
    });

    test('regression guard (passes today): a gesture that counted reports '
        'nothing', () async {
      final r = AkEcgRig(max: 3, reportFailures: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      expect(r.results, [(3, null)]);
      expect(r.failures, isEmpty);
    });

    test('a start the retry cured reports nothing', () async {
      final r = AkEcgRig(
          max: 3, begins: const [false, true], reportFailures: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      expect(r.results, [(3, null)]);
      expect(r.failures, isEmpty);
    });
  });
}
