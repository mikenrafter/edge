import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_assembler.dart';

import 'outcome_rig.dart';

Map<String, Object?> jsonRoundTrip(Map<String, Object?> j) =>
    (jsonDecode(jsonEncode(j)) as Map).cast<String, Object?>();

WakeOutcome run({
  int wake = kT,
  required List trace,
  List<int> app = const [],
  List<int> move = const [],
  int? grogginess,
  List<int> others = const [],
}) =>
    assemble(
      wakeSec: wake,
      trace: [for (final t in trace) ...(t is List ? t : [t])].cast(),
      appInteractionSecs: app,
      movementSecs: move,
      grogginess: grogginess,
      otherAlarmSecs: others,
    );

void main() {
  const fire = kT - 1800; // a Natural fire 30 min before T

  group('natural fire', () {
    test('delivered, with all three responses', () {
      final o = run(
        trace: [
          naturalFire(kT, fire),
          [ackRow(kT, fire + 90)],
        ],
        app: [fire + 240],
        move: [fire + 45],
      );
      expect(o.wakeSec, kT);
      expect(o.firedBy, WakeFiredBy.natural);
      expect(o.firedAtSec, fire);
      expect(o.stageAtFire, 'rem');
      expect(o.stageAgeSec, 30);
      expect(o.delivered, isTrue);
      expect(o.minutesBeforeT, 30.0);
      expect(o.latencySec, {
        WakeResponseKind.deliberateAck: 90,
        WakeResponseKind.appInteraction: 240,
        WakeResponseKind.movement: 45,
      });
      expect(o.exclusions, isEmpty);
      expect(o.usable, isTrue);
      expect(o.grogginess, isNull);
    });

    test('a wake stage is reported as awake', () {
      final o = run(trace: [naturalFire(kT, fire, stage: 'wake')]);
      expect(o.stageAtFire, 'awake');
    });

    test('grogginess is passed through, null stays null', () {
      expect(run(trace: [naturalFire(kT, fire)], grogginess: 4).grogginess, 4);
      expect(run(trace: [naturalFire(kT, fire)]).grogginess, isNull);
    });

    test('a first delivery that failed is not a natural fire', () {
      final o = run(trace: [naturalNotDelivered(kT, fire)]);
      expect(o.firedBy, WakeFiredBy.none);
      expect(o.delivered, isFalse);
    });

    test('rows of another wake are ignored; unsorted input is fine', () {
      final other = kT + 86400;
      final o = run(
        trace: [
          naturalFire(other, other - 600), // another night entirely
          naturalFire(kT, fire).reversed.toList(),
        ],
        app: [fire + 300, fire + 60, fire + 60],
      );
      expect(o.firedBy, WakeFiredBy.natural);
      expect(o.firedAtSec, fire);
      expect(o.latencySec[WakeResponseKind.appInteraction], 60);
    });
  });

  group('responses are separate and never fabricated', () {
    test('not seen stays null: all three keys present, never 0', () {
      final o = run(trace: [naturalFire(kT, fire)]);
      expect(o.latencySec.keys, unorderedEquals(WakeResponseKind.values));
      expect(o.latencySec.values, everyElement(isNull));
      expect(o.usable, isTrue);
    });

    test('an app open before the fire is not a zero latency', () {
      // 20 min before the fire: outside the already-awake window, still no
      // latency.
      final o = run(trace: [naturalFire(kT, fire)], app: [fire - 1200]);
      expect(o.latencySec[WakeResponseKind.appInteraction], isNull);
      expect(o.exclusions, isEmpty);
    });

    test('an app open within 10 min before the fire means already awake', () {
      final o = run(trace: [naturalFire(kT, fire)], app: [fire - 300]);
      expect(o.latencySec[WakeResponseKind.appInteraction], isNull);
      expect(o.exclusions, [WakeExclusion.alreadyAwake]);
      expect(o.usable, isFalse);
    });

    test('an open at the fire second is pre-fire: no latency, already awake',
        () {
      final o = run(trace: [naturalFire(kT, fire)], app: [fire]);
      expect(o.latencySec[WakeResponseKind.appInteraction], isNull);
      expect(o.exclusions, [WakeExclusion.alreadyAwake]);
    });

    test('a pre-fire open and a later one: only the later one is a latency',
        () {
      final o =
          run(trace: [naturalFire(kT, fire)], app: [fire - 300, fire + 60]);
      expect(o.latencySec[WakeResponseKind.appInteraction], 60);
      expect(o.exclusions, [WakeExclusion.alreadyAwake]);
    });

    test('movement before the fire never counts', () {
      final o = run(
          trace: [naturalFire(kT, fire)], move: [fire - 30, fire, fire + 500]);
      expect(o.latencySec[WakeResponseKind.movement], 500);
      expect(o.exclusions, isEmpty); // only an app touch means already awake
    });

    test('a band double tap that stops the repeat is a deliberate ack', () {
      final o = run(trace: [
        naturalFire(kT, fire),
        [repeatStart(kT, fire + 5), repeatStop(kT, fire + 120, 'bandDoubleTap')],
      ]);
      expect(o.latencySec[WakeResponseKind.deliberateAck], 120);
    });

    test('a repeat stopped by acknowledgement counts; the earliest wins', () {
      final o = run(trace: [
        naturalFire(kT, fire),
        [ackRow(kT, fire + 150), repeatStop(kT, fire + 200, 'acknowledged')],
      ]);
      expect(o.latencySec[WakeResponseKind.deliberateAck], 150);
    });

    for (final reason in ['wakeTime', 'headlessBound', 'disposed']) {
      test('a repeat that stopped for "$reason" is no response', () {
        final o = run(trace: [
          naturalFire(kT, fire),
          [repeatStop(kT, fire + 900, reason)],
        ]);
        expect(o.latencySec[WakeResponseKind.deliberateAck], isNull);
      });
    }

    test('an ack row before the fire does not count', () {
      final o = run(trace: [
        naturalFire(kT, fire),
        [ackRow(kT, fire - 60)],
      ]);
      expect(o.latencySec[WakeResponseKind.deliberateAck], isNull);
    });
  });

  group('who fired', () {
    test('gradual only: first sent step is the fire', () {
      final o = run(trace: [
        [
          gradualRow(kT, kT - 900, 0, 'skippedLate'),
          gradualRow(kT, kT - 700, 1, 'notDelivered'),
          gradualRow(kT, kT - 600, 2, 'sent'),
          gradualRow(kT, kT - 300, 3, 'sent'),
        ],
      ], move: [kT - 540]);
      expect(o.firedBy, WakeFiredBy.gradual);
      expect(o.firedAtSec, kT - 600);
      expect(o.stageAtFire, isNull);
      expect(o.stageAgeSec, isNull);
      expect(o.minutesBeforeT, 10.0);
      expect(o.delivered, isTrue);
      expect(o.latencySec[WakeResponseKind.movement], 60);
      expect(o.usable, isTrue);
    });

    test('gradual steps that never landed are no delivery', () {
      final o = run(trace: [
        [gradualRow(kT, kT - 600, 0, 'notDelivered')],
      ]);
      expect(o.firedBy, WakeFiredBy.none);
      expect(o.delivered, isFalse);
      expect(o.exclusions, [WakeExclusion.noDelivery]);
    });

    test('natural wins when natural and gradual both fired', () {
      final o = run(trace: [
        naturalFire(kT, fire),
        [gradualRow(kT, kT - 600, 0, 'sent')],
      ]);
      expect(o.firedBy, WakeFiredBy.natural);
      expect(o.firedAtSec, fire);
    });

    test('native with an armed fallback is delivered at T', () {
      final o = run(trace: [
        [fallbackRow(kT, kT - 7200), closedRow(kT, kT + 60)],
      ], move: [kT + 30], app: [kT + 200]);
      expect(o.firedBy, WakeFiredBy.native);
      expect(o.firedAtSec, kT);
      expect(o.minutesBeforeT, 0.0);
      expect(o.delivered, isTrue);
      expect(o.latencySec[WakeResponseKind.movement], 30);
      expect(o.latencySec[WakeResponseKind.appInteraction], 200);
      expect(o.exclusions, isEmpty);
    });

    test('native whose fallback was re-armed counts as armed', () {
      final o = run(trace: [
        [
          fallbackRow(kT, kT - 7200, armed: true, confirmed: false, rearmed: true),
          closedRow(kT, kT + 60),
        ],
      ]);
      expect(o.delivered, isTrue);
    });

    test('native without an armed fallback is not delivered', () {
      final o = run(trace: [
        [
          fallbackRow(kT, kT - 7200, armed: false, confirmed: false),
          closedRow(kT, kT + 60),
        ],
      ]);
      expect(o.firedBy, WakeFiredBy.native);
      expect(o.delivered, isFalse);
      expect(o.exclusions, [WakeExclusion.noDelivery]);
      expect(o.usable, isFalse);
    });

    test('native with no fallback row at all is not delivered', () {
      final o = run(trace: [
        [closedRow(kT, kT + 60)],
      ]);
      expect(o.firedBy, WakeFiredBy.native);
      expect(o.delivered, isFalse);
      expect(o.exclusions, [WakeExclusion.noDelivery]);
    });

    test('the last fallback row decides', () {
      final o = run(trace: [
        [
          fallbackRow(kT, kT - 7200, armed: true),
          fallbackRow(kT, kT - 3600, armed: false, confirmed: false),
          closedRow(kT, kT + 60),
        ],
      ]);
      expect(o.delivered, isFalse);
    });

    test('nothing fired and T not reached: none, no delivery, no responses',
        () {
      final o = run(trace: const [], app: [kT + 10], move: [kT + 10]);
      expect(o.firedBy, WakeFiredBy.none);
      expect(o.firedAtSec, isNull);
      expect(o.minutesBeforeT, isNull);
      expect(o.delivered, isFalse);
      expect(o.exclusions, [WakeExclusion.noDelivery]);
      expect(o.latencySec.keys, unorderedEquals(WakeResponseKind.values));
      expect(o.latencySec.values, everyElement(isNull));
      expect(o.usable, isFalse);
    });
  });

  group('exclusions', () {
    test('stale stage evidence (over 180 s) excludes', () {
      final o = run(trace: [naturalFire(kT, fire, evidenceAgeMs: 200000)]);
      expect(o.stageAgeSec, 200);
      expect(o.exclusions, [WakeExclusion.staleStage]);
      expect(o.usable, isFalse);
    });

    test('evidence exactly 180 s old is not stale', () {
      final o = run(trace: [naturalFire(kT, fire, evidenceAgeMs: 180000)]);
      expect(o.stageAgeSec, 180);
      expect(o.exclusions, isEmpty);
    });

    test('another alarm within 15 min before the fire excludes', () {
      final o = run(trace: [naturalFire(kT, fire)], others: [fire - 600]);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
      expect(o.usable, isFalse);
    });

    test('an alarm over 15 min before, or after the fire, does not', () {
      final o = run(
          trace: [naturalFire(kT, fire)], others: [fire - 1000, fire + 300]);
      expect(o.exclusions, isEmpty);
    });

    test('a first response over 4 h after the fire is another episode', () {
      final o = run(
          trace: [naturalFire(kT, fire)], app: [fire + 5 * 3600], move: []);
      expect(o.latencySec[WakeResponseKind.appInteraction], isNull);
      expect(o.exclusions, [WakeExclusion.crossedEpisode]);
      expect(o.usable, isFalse);
    });

    test('all responses past 4 h are censored', () {
      final o = run(
          trace: [naturalFire(kT, fire)],
          app: [fire + 6 * 3600],
          move: [fire + 5 * 3600]);
      expect(o.latencySec.values, everyElement(isNull));
      expect(o.exclusions, [WakeExclusion.crossedEpisode]);
    });

    test('exactly 4 h after the fire is kept', () {
      final o = run(trace: [naturalFire(kT, fire)], app: [fire + 4 * 3600]);
      expect(o.latencySec[WakeResponseKind.appInteraction], 14400);
      expect(o.exclusions, isEmpty);
    });

    test('a late response after an earlier one is censored, not excluded', () {
      final o = run(
        trace: [
          naturalFire(kT, fire),
          [ackRow(kT, fire + 100)],
        ],
        app: [fire + 5 * 3600],
      );
      expect(o.latencySec[WakeResponseKind.deliberateAck], 100);
      expect(o.latencySec[WakeResponseKind.appInteraction], isNull);
      expect(o.exclusions, isEmpty);
    });

    test('several exclusions are listed once each, in enum order', () {
      final o = run(
        trace: [naturalFire(kT, fire, evidenceAgeMs: 300000)],
        app: [fire - 120],
        others: [fire - 60],
      );
      expect(o.exclusions, [
        WakeExclusion.alreadyAwake,
        WakeExclusion.staleStage,
        WakeExclusion.competingAlarm,
      ]);
    });
  });

  group('time is epoch seconds', () {
    test('a DST night (US spring forward) needs no day-length arithmetic', () {
      // 2026-03-08: 02:00 EST -> 03:00 EDT, a 23 h night. T = 07:00 EDT =
      // 11:00 UTC.
      final t = DateTime.utc(2026, 3, 8, 11).millisecondsSinceEpoch ~/ 1000;
      final f = t - 40 * 60;
      WakeOutcome at(int shift) => run(
            wake: t + shift,
            trace: [
              naturalFire(t + shift, f + shift),
              [ackRow(t + shift, f + shift + 300)],
            ],
            app: [f + shift + 420],
            move: [f + shift + 90],
          );
      final dst = at(0);
      expect(dst.firedAtSec, f);
      expect(dst.minutesBeforeT, 40.0);
      expect(dst.latencySec, {
        WakeResponseKind.deliberateAck: 300,
        WakeResponseKind.appInteraction: 420,
        WakeResponseKind.movement: 90,
      });
      // The same night a day later (23 h or 24 h of wall clock, it must not
      // matter) gives the same answer.
      final next = at(86400);
      expect(next.latencySec, dst.latencySec);
      expect(next.minutesBeforeT, dst.minutesBeforeT);
    });
  });

  group('WakeOutcome json', () {
    test('round trips, nulls and keys included', () {
      final o = run(
        trace: [naturalFire(kT, fire, stage: 'wake')],
        app: [fire - 120, fire + 75],
        others: [fire - 30],
        grogginess: 3,
      );
      final j = o.toJson();
      expect(() => jsonRoundTrip(j), returnsNormally);
      final back = WakeOutcome.fromJson(jsonRoundTrip(j));
      expect(back.toJson(), j);
      expect(back.wakeSec, kT);
      expect(back.firedBy, WakeFiredBy.natural);
      expect(back.stageAtFire, 'awake');
      expect(back.grogginess, 3);
      expect(back.latencySec.keys, unorderedEquals(WakeResponseKind.values));
      expect(back.latencySec[WakeResponseKind.appInteraction], 75);
      expect(back.latencySec[WakeResponseKind.movement], isNull);
      expect(back.exclusions,
          [WakeExclusion.alreadyAwake, WakeExclusion.competingAlarm]);
    });
  });
}
