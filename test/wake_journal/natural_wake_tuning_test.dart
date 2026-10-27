// This is a proposed product policy for GREEN, not a validated sleep metric.
// Seven distinct complete outcomes; newest eligible Natural outcome moves at
// most once. Fast dream + no snooze + recovery >=50 + TST >=6 h: -15 s/+1 min.
// Slow normal (>=10 min or >=2 snoozes) with the same context: +15 s/-1 min.
// Unknown context or low recovery/short sleep holds the current parameters.
// Dream-context score weights Natural=1, other paths=.25; it is not a medical
// probability and must never be presented as stage accuracy.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake_tuning.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'fixtures.dart';

List<WakeNightOutcome> good(int n) => [for (var i = 0; i < n; i++) outcome(i)];
void expectParameters(NaturalTuningDecision d, int trigger, int lead) {
  expect(d.parameters.triggerRunOffsetSec, trigger);
  expect(d.parameters.windowLeadMinutes, lead);
}

void main() {
  test('empty history keeps defaults and has no dream context', () {
    final d = NaturalWakeTuning.evaluate([]);
    expectParameters(d, 0, 0);
    expect(d.eligibleNights, 0);
    expect(d.applied, isFalse);
    expect(d.dreamContextScore, isNull);
  });

  test(
    'skipped dream questions retain outcomes but cannot fabricate dream context',
    () {
      final d = NaturalWakeTuning.evaluate([
        for (var i = 0; i < 7; i++) outcome(i, answer: null),
      ]);
      expect(d.eligibleNights, 7);
      expectParameters(d, 0, 0);
      expect(d.dreamContextScore, isNull);
      expect(d.applied, isFalse);
    },
  );

  test('six nights hold; the seventh makes exactly one small nudge', () {
    final six = NaturalWakeTuning.evaluate(good(6));
    expectParameters(six, 0, 0);
    expect(six.eligibleNights, 6);
    expect(six.applied, isFalse);
    final seven = NaturalWakeTuning.evaluate(good(7));
    expectParameters(seven, -15, 1);
    expect(seven.eligibleNights, 7);
    expect(seven.applied, isTrue);
    expect(seven.reason, 'natural_dream_fast');
    expect(seven.parameters.lastLearnedEpoch, epoch + 6 * 86400);
  });

  test(
    'slow normal wakes with snoozes move only one step in the other direction',
    () {
      final d = NaturalWakeTuning.evaluate([
        for (var i = 0; i < 7; i++)
          outcome(i, answer: DreamAnswer.normal, minutes: 12, snoozes: 3),
      ]);
      expectParameters(d, 15, -1);
      expect(d.reason, 'natural_normal_slow');
    },
  );

  test(
    'fixed history replays exactly despite ordering and identical duplicate epochs',
    () {
      final history = good(7);
      for (final input in [
        history,
        history.reversed.toList(),
        [...history, history[3]],
      ]) {
        final d = NaturalWakeTuning.evaluate(input);
        expectParameters(
          d,
          -15,
          1,
        ); // literal expected output, never learned from this stub
        expect(d.eligibleNights, 7);
        expect(d.dreamContextScore, 1);
        expect(d.reason, 'natural_dream_fast');
        expect(d.parameters.lastLearnedEpoch, epoch + 6 * 86400);
      }
    },
  );

  test(
    'replay after application and repeated sync cannot apply twice for one night',
    () {
      final history = good(7);
      final once = NaturalWakeTuning.evaluate(
        history,
        current: NaturalWakeParameters(
          triggerRunOffsetSec: -15,
          windowLeadMinutes: 1,
          lastLearnedEpoch: epoch + 6 * 86400,
        ),
      );
      expectParameters(once, -15, 1);
      expect(once.applied, isFalse);
      final sameNight = NaturalWakeTuning.evaluate(
        [...history, outcome(6, wakeOffsetSec: 600)],
        current: NaturalWakeParameters(
          triggerRunOffsetSec: -15,
          windowLeadMinutes: 1,
          lastLearnedEpoch: epoch + 6 * 86400,
        ),
      );
      expectParameters(sameNight, -15, 1);
      expect(
        sameNight.applied,
        isFalse,
        reason: 'a later alarm epoch on the same sleep day is not a new night',
      );

      final next = NaturalWakeTuning.evaluate(
        good(8),
        current: NaturalWakeParameters(
          triggerRunOffsetSec: -15,
          windowLeadMinutes: 1,
          lastLearnedEpoch: epoch + 6 * 86400,
        ),
      );
      expectParameters(next, -30, 2);
      expect(next.parameters.lastLearnedEpoch, epoch + 7 * 86400);
    },
  );

  test(
    'a long history still moves only once when processing the newest night',
    () {
      final d = NaturalWakeTuning.evaluate(good(40));
      expectParameters(d, -15, 1);
      expect(d.parameters.lastLearnedEpoch, epoch + 39 * 86400);
    },
  );

  test('lower bounds and upper lead clamp, including a partial final step', () {
    final atEdge = NaturalWakeTuning.evaluate(
      good(7),
      current: const NaturalWakeParameters(
        triggerRunOffsetSec: -60,
        windowLeadMinutes: 10,
      ),
    );
    expectParameters(atEdge, -60, 10);
    expect(atEdge.applied, isFalse);
    final partial = NaturalWakeTuning.evaluate(
      good(7),
      current: const NaturalWakeParameters(
        triggerRunOffsetSec: -50,
        windowLeadMinutes: 10,
      ),
    );
    expectParameters(partial, -60, 10);
    expect(partial.applied, isTrue);
  });

  test('upper trigger and lower lead clamp on difficult wakes', () {
    final d = NaturalWakeTuning.evaluate(
      [
        for (var i = 0; i < 7; i++)
          outcome(i, answer: DreamAnswer.normal, minutes: 12, snoozes: 3),
      ],
      current: const NaturalWakeParameters(
        triggerRunOffsetSec: 60,
        windowLeadMinutes: -10,
      ),
    );
    expectParameters(d, 60, -10);
    expect(d.applied, isFalse);
  });

  test('seven alarm epochs on one main-sleep day count as one night', () {
    final d = NaturalWakeTuning.evaluate([
      for (var i = 0; i < 7; i++) outcome(0, wakeOffsetSec: i * 600),
    ]);
    expect(d.eligibleNights, 1);
    expectParameters(d, 0, 0);
    expect(d.applied, isFalse);
  });

  test('seven copies of one night never satisfy warm-up', () {
    final d = NaturalWakeTuning.evaluate(List.filled(7, outcome(0)));
    expect(d.eligibleNights, 1);
    expect(d.applied, isFalse);
  });

  test('missing time to wake or snooze count is not an observed outcome', () {
    final d = NaturalWakeTuning.evaluate([
      ...good(6),
      outcome(6, minutes: null),
      outcome(7, snoozes: null),
    ]);
    expect(d.eligibleNights, 6);
    expectParameters(d, 0, 0);
    expect(d.applied, isFalse);
  });

  test(
    'alcohol warm-up is independent and suppresses early-REM expectations tonight',
    () {
      // Ebrahim 2013, doi:10.1111/acer.12006: first-half REM suppressed/delayed.
      final d = NaturalWakeTuning.evaluate([
        ...good(6),
        outcome(6, substance: WakeSubstance.alcohol),
      ], tonightSubstance: WakeSubstance.alcohol);
      expect(d.eligibleNights, 1);
      expect(d.expectEarlyRem, isFalse);
      expectParameters(d, 0, 0);
      expect(d.applied, isFalse);
    },
  );

  test(
    'an alcohol-tagged latest night never nudges from the seven earlier nights',
    () {
      final d = NaturalWakeTuning.evaluate([
        ...good(7),
        outcome(7, substance: WakeSubstance.alcohol),
      ]);
      expect(d.eligibleNights, 1);
      expect(d.applied, isFalse);
      expectParameters(d, 0, 0);
    },
  );

  test('cannabis tag alone does not assert chronic REM suppression', () {
    final d = NaturalWakeTuning.evaluate([
      for (var i = 0; i < 7; i++) outcome(i, substance: WakeSubstance.cannabis),
    ], tonightSubstance: WakeSubstance.cannabis);
    expect(d.expectEarlyRem, isTrue);
    expect(d.eligibleNights, 7);
    expectParameters(d, -15, 1);
  });

  for (final context in [
    'low_recovery',
    'short_sleep',
    'missing_recovery',
    'missing_tst',
  ]) {
    test(
      '$context holds the detector parameters without inventing context',
      () {
        final d = NaturalWakeTuning.evaluate(
          [
            ...good(6),
            outcome(
              6,
              recovery: context == 'missing_recovery'
                  ? null
                  : context == 'low_recovery'
                  ? 30
                  : 80,
              tstMinutes: context == 'missing_tst'
                  ? null
                  : context == 'short_sleep'
                  ? 240
                  : 480,
            ),
          ],
          current: const NaturalWakeParameters(
            triggerRunOffsetSec: 15,
            windowLeadMinutes: -1,
          ),
        );
        expectParameters(d, 15, -1);
        expect(d.applied, isFalse);
        expect(d.eligibleNights, 7);
      },
    );
  }

  test(
    'non-Natural answers feed end-stage context but do not tune a stage-timed trigger',
    () {
      final d = NaturalWakeTuning.evaluate([
        for (var i = 0; i < 7; i++)
          outcome(i, path: i.isEven ? WakePath.gradual : WakePath.alarm),
      ]);
      expect(d.eligibleNights, 7);
      expect(d.dreamContextScore, 1);
      expect(d.applied, isFalse);
    },
  );

  test('Natural-timed dream answers have four times the contextual weight', () {
    final natural = NaturalWakeTuning.evaluate([
      for (var i = 0; i < 6; i++) outcome(i),
      outcome(6, path: WakePath.alarm, answer: DreamAnswer.normal),
    ]);
    final other = NaturalWakeTuning.evaluate([
      for (var i = 0; i < 6; i++) outcome(i, path: WakePath.alarm),
      outcome(6, answer: DreamAnswer.normal),
    ]);
    expect(natural.dreamContextScore, closeTo(.96, 1e-12)); // 6 / (6 + .25)
    expect(other.dreamContextScore, closeTo(.6, 1e-12)); // 1.5 / (1.5 + 1)
  });

  test(
    'invalid negative outcomes are excluded, never coerced to an easy wake',
    () {
      final d = NaturalWakeTuning.evaluate([
        ...good(6),
        outcome(6, minutes: -1),
        outcome(7, snoozes: -1),
      ]);
      expect(d.eligibleNights, 6);
      expectParameters(d, 0, 0);
      expect(d.applied, isFalse);
    },
  );
}
