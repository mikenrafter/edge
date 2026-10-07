// ECG features, phase 1 (RED): which end state plays which ECG haptic slot, and
// where the S.O.S. (ecg.attention) is and is not used.
//
// EcgCueTracker (lib/ecg/ecg_cues.dart) is fed every state the controller
// publishes, in order, and answers the slot to play or null. The table is in
// that file's header. The decision this file pins: S.O.S. is for "look at the
// phone, the band may still be recording" (cleanup incomplete, a retained guard
// that could not be cleared), NEVER for what a reading found. ECG here is a
// screen, not a diagnostic device; no outcome of a reading is an alarm.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_cues.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';

EcgCaptureState _s(
  EcgCapturePhase phase, {
  String? reason,
  EcgReadingStatus? result,
  bool cleanupIncomplete = false,
  String? readingId,
}) => EcgCaptureState(
  phase: phase,
  reason: reason,
  result: result,
  cleanupIncomplete: cleanupIncomplete,
  readingId: readingId,
);

/// Every non-null cue the tracker answers over [states], in order.
List<String> _cues(Iterable<EcgCaptureState> states, [EcgCueTracker? t]) {
  final tr = t ?? EcgCueTracker();
  return [
    for (final s in states) ?tr.observe(s),
  ];
}

const _lead = [
  EcgCapturePhase.preparing,
  EcgCapturePhase.starting,
  EcgCapturePhase.waiting,
];

List<EcgCaptureState> _recording() => [
  for (final p in _lead) _s(p),
  _s(EcgCapturePhase.active),
  _s(EcgCapturePhase.active),
  _s(EcgCapturePhase.contactLost),
  _s(EcgCapturePhase.active),
];

void main() {
  group('started', () {
    test('plays once, on the first active of a capture', () {
      expect(_cues(_recording()), [kEcgStartedKey]);
    });

    test('not while only waiting for contact', () {
      expect(_cues([for (final p in _lead) _s(p)]), isEmpty);
    });

    test('a new capture after reset() starts again', () {
      final t = EcgCueTracker();
      expect(_cues(_recording(), t), [kEcgStartedKey]);
      t.reset();
      expect(_cues(_recording(), t), [kEcgStartedKey]);
    });
  });

  group('the end states', () {
    test('a good recording: started, then complete', () {
      expect(
        _cues([
          ..._recording(),
          _s(EcgCapturePhase.saving),
          _s(EcgCapturePhase.cleaningUp),
          _s(
            EcgCapturePhase.completed,
            result: EcgReadingStatus.completed,
            readingId: 'r1',
          ),
        ]),
        [kEcgStartedKey, kEcgCompleteKey],
      );
    });

    test('a final inconclusive (the retry was already used): inconclusive', () {
      expect(
        _cues([
          ..._recording(),
          _s(
            EcgCapturePhase.completed,
            result: EcgReadingStatus.inconclusive,
            readingId: 'r1',
          ),
        ]),
        [kEcgStartedKey, kEcgInconclusiveKey],
      );
    });

    test('inconclusive with another reading requested: its own slot, not the '
        'plain inconclusive one', () {
      expect(
        _cues([..._recording(), _s(EcgCapturePhase.inconclusiveRetry)]),
        [kEcgStartedKey, kEcgInconclusiveRetryKey],
      );
    });

    test('the retry flow: started, retry asked, started again, then the final '
        'inconclusive', () {
      final t = EcgCueTracker();
      final out = <String>[
        ..._cues([..._recording(), _s(EcgCapturePhase.inconclusiveRetry)], t),
      ];
      t.reset(); // the controller resets on every begin()
      out.addAll(_cues([
        ..._recording(),
        _s(EcgCapturePhase.completed,
            result: EcgReadingStatus.inconclusive, readingId: 'r2'),
      ], t));
      expect(out, [
        kEcgStartedKey,
        kEcgInconclusiveRetryKey,
        kEcgStartedKey,
        kEcgInconclusiveKey,
      ]);
    });

    test('the band could not read it: failed', () {
      expect(
        _cues([..._recording(), _s(EcgCapturePhase.unreadable)]),
        [kEcgStartedKey, kEcgFailedKey],
      );
    });

    for (final reason in ['disconnected', 'timeout', 'malformed', 'interruptions',
        'prepare', 'start', 'restart', 'save', 'error']) {
      test('failed ($reason): failed', () {
        expect(_cues([_s(EcgCapturePhase.failed, reason: reason)]),
            [kEcgFailedKey]);
      });
    }

    test('a failure before anything started plays failed only, no started', () {
      expect(
        _cues([
          _s(EcgCapturePhase.preparing),
          _s(EcgCapturePhase.failed, reason: 'prepare'),
        ]),
        [kEcgFailedKey],
      );
    });

    test('the app went to the background (cancelled, paused): failed, with or '
        'without a partial saved', () {
      for (final result in [null, EcgReadingStatus.partial]) {
        expect(
          _cues([
            ..._recording(),
            _s(EcgCapturePhase.cancelled,
                reason: 'paused', result: result, readingId: result == null ? null : 'p1'),
          ]),
          [kEcgStartedKey, kEcgFailedKey],
          reason: 'result=$result',
        );
      }
    });

    test('a timed-out capture with a partial saved: failed', () {
      expect(
        _cues([
          ..._recording(),
          _s(EcgCapturePhase.failed,
              reason: 'timeout', result: EcgReadingStatus.partial, readingId: 'p1'),
        ]),
        [kEcgStartedKey, kEcgFailedKey],
      );
    });
  });

  group('no cue', () {
    for (final reason in ['cancelled', 'gesture', 'disposed']) {
      test('cancelled ($reason) is the wearer\'s own doing: silent', () {
        expect(
          _cues([..._recording(), _s(EcgCapturePhase.cancelled, reason: reason)]),
          [kEcgStartedKey],
        );
      });
    }

    for (final p in [
      EcgCapturePhase.idle,
      EcgCapturePhase.incompatible,
      EcgCapturePhase.disconnected,
      EcgCapturePhase.busy,
    ]) {
      test('${p.name}: nothing happened on the band, silent', () {
        expect(_cues([_s(p, reason: p == EcgCapturePhase.busy ? 'workout' : null)]),
            isEmpty);
      });
    }

    test('a terminal cue fires once even if the same terminal state is '
        'published again (a readingId update)', () {
      final t = EcgCueTracker();
      expect(
        _cues([
          ..._recording(),
          _s(EcgCapturePhase.completed, result: EcgReadingStatus.completed),
          _s(EcgCapturePhase.completed,
              result: EcgReadingStatus.completed, readingId: 'r1'),
        ], t),
        [kEcgStartedKey, kEcgCompleteKey],
      );
    });
  });

  group('S.O.S. (ecg.attention)', () {
    test('a cleanup that did not finish: the band may still be recording, so '
        'the cue for ANY terminal is attention', () {
      final ends = <EcgCaptureState>[
        _s(EcgCapturePhase.completed,
            result: EcgReadingStatus.completed, cleanupIncomplete: true),
        _s(EcgCapturePhase.completed,
            result: EcgReadingStatus.inconclusive, cleanupIncomplete: true),
        _s(EcgCapturePhase.inconclusiveRetry, cleanupIncomplete: true),
        _s(EcgCapturePhase.unreadable, cleanupIncomplete: true),
        _s(EcgCapturePhase.failed, reason: 'disconnected', cleanupIncomplete: true),
        _s(EcgCapturePhase.cancelled, reason: 'paused', cleanupIncomplete: true),
        _s(EcgCapturePhase.cancelled, reason: 'cancelled', cleanupIncomplete: true),
      ];
      for (final e in ends) {
        expect(_cues([_s(EcgCapturePhase.cleaningUp), e]), [kEcgAttentionKey],
            reason: '${e.phase} ${e.reason} ${e.result}');
      }
    });

    test('a retained guard that could not be cleared (recovery failed) is '
        'attention too', () {
      expect(_cues([_s(EcgCapturePhase.failed, reason: 'recovery')]),
          [kEcgAttentionKey]);
    });

    test('and ONLY there: across every phase, reason and result with a clean '
        'cleanup, attention is played for nothing but a failed recovery', () {
      const reasons = <String?>[
        null, 'disconnected', 'timeout', 'malformed', 'interruptions', 'prepare',
        'start', 'restart', 'save', 'error', 'guard', 'no_serial', 'recovery',
        'cancelled', 'paused', 'gesture', 'disposed', 'workout', 'transport',
        'progress_255',
      ];
      final results = <EcgReadingStatus?>[null, ...EcgReadingStatus.values];
      for (final phase in EcgCapturePhase.values) {
        for (final reason in reasons) {
          for (final result in results) {
            final cue = EcgCueTracker().observe(
              _s(phase, reason: reason, result: result),
            );
            final expectAttention =
                phase == EcgCapturePhase.failed && reason == 'recovery';
            expect(cue == kEcgAttentionKey, expectAttention,
                reason: 'phase=$phase reason=$reason result=$result cue=$cue');
          }
        }
      }
    });

    test('no reading outcome is an alarm: every saved status, finished clean, '
        'plays an outcome cue and never the S.O.S.', () {
      for (final status in EcgReadingStatus.values) {
        final phase = status == EcgReadingStatus.partial
            ? EcgCapturePhase.failed
            : EcgCapturePhase.completed;
        final cue = EcgCueTracker().observe(_s(
          phase,
          reason: status == EcgReadingStatus.partial ? 'timeout' : null,
          result: status,
          readingId: 'r',
        ));
        expect(cue, isNotNull, reason: '$status');
        expect(cue, isNot(kEcgAttentionKey), reason: '$status');
      }
    });
  });
}
