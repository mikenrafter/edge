import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_assembler.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart' show WakeTraceEntry;

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

    test('a sent Natural repeat delivers after the first haptic failed', () {
      final repeatFire = fire + 30;
      final o = run(trace: [
        naturalNotDelivered(kT, fire),
        row(kT, repeatFire, 'natural_repeat', {
          'phase': 'result',
          'index': 1,
          'result': 'sent',
          'suppression': null,
          'error': null,
        }),
      ]);
      expect(o.firedBy, WakeFiredBy.natural);
      expect(o.firedAtSec, repeatFire);
      expect(o.delivered, isTrue);
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

    // RED-EDIT (P2 native confirmation): this test used `confirmed: false` and
    // expected delivered, i.e. it encoded "armed but unconfirmed counts". Armed
    // AND confirmed is the delivery claim, so the re-armed row is now confirmed.
    test('native whose fallback was re-armed and confirmed counts as armed', () {
      final o = run(trace: [
        [
          fallbackRow(kT, kT - 7200, armed: true, confirmed: true, rearmed: true),
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

  group('band delivery is a band target, not "sent" (P2)', () {
    test('Natural sent to the PHONE only is no band delivery', () {
      // The transport reports result 'sent' when ANY target succeeds; the band
      // output was rejected, so `delivered` lists only 'phone'.
      final o = run(trace: [naturalFire(kT, fire, targets: const ['phone'])]);
      expect(o.delivered, isFalse);
      expect(o.exclusions, contains(WakeExclusion.noDelivery));
      expect(o.usable, isFalse);
    });

    test('Natural sent to phone and band is delivered', () {
      final o = run(
          trace: [naturalFire(kT, fire, targets: const ['phone', 'band'])]);
      expect(o.delivered, isTrue);
      expect(o.exclusions, isEmpty);
    });

    // RED-EDIT (round 3, P2): this test used to expect NO exclusion. Wrong: the
    // phone sounded at `fire`, a minute before the band repeat, so the wearer's
    // response cannot be told apart from the phone's wake stimulus. Delivery
    // stands (the repeat did reach the band); the morning is not comparable.
    test('a phone-only first fire, then a band-only repeat a minute later: the '
        'repeat is the fire, but the earlier phone stimulus contaminates it',
        () {
      final repeatFire = fire + 60;
      final o = run(trace: [
        naturalFire(kT, fire, targets: const ['phone']),
        // natural_repeat results carry no `delivered` list: the repeat sends
        // with transportTargets {'band'}, so 'sent' there means the band.
        [
          row(kT, repeatFire, 'natural_repeat', {
            'phase': 'result',
            'index': 1,
            'result': 'sent',
            'suppression': null,
            'error': null,
          }),
        ],
      ]);
      expect(o.delivered, isTrue);
      expect(o.firedAtSec, repeatFire);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
      expect(o.usable, isFalse);
    });

    test('Gradual step sent to the PHONE only is no band delivery', () {
      final o = run(trace: [
        [gradualRow(kT, kT - 600, 0, 'sent', targets: const ['phone'])],
      ]);
      expect(o.delivered, isFalse);
      expect(o.exclusions, contains(WakeExclusion.noDelivery));
      expect(o.usable, isFalse);
    });

    test('native armed but NOT confirmed is not delivered', () {
      final o = run(trace: [
        [
          fallbackRow(kT, kT - 7200, armed: true, confirmed: false),
          closedRow(kT, kT + 60),
        ],
      ]);
      expect(o.delivered, isFalse);
      expect(o.exclusions, contains(WakeExclusion.noDelivery));
      expect(o.usable, isFalse);
    });

    test('native armed with an unknown (null) confirmation is not delivered',
        () {
      final o = run(trace: [
        [
          row(kT, kT - 7200, 'fallback',
              {'armed': true, 'confirmed': null, 'rearmed': false}),
          closedRow(kT, kT + 60),
        ],
      ]);
      expect(o.delivered, isFalse);
      expect(o.usable, isFalse);
    });
  });

  group('competing wake stimuli are not attributed to Natural (P2)', () {
    test('Gradual delivered at T-15 min, Natural at T-10 min: excluded', () {
      final naturalAt = kT - 600;
      final o = run(trace: [
        [gradualRow(kT, kT - 900, 0, 'sent')],
        naturalFire(kT, naturalAt),
      ], move: [naturalAt + 30]);
      expect(o.exclusions, contains(WakeExclusion.competingAlarm));
      expect(o.usable, isFalse);
    });

    test('several earlier Gradual steps inside the 15 min: excluded', () {
      final naturalAt = kT - 600;
      final o = run(trace: [
        [
          gradualRow(kT, naturalAt - 840, 0, 'sent'),
          gradualRow(kT, naturalAt - 600, 1, 'sent'),
          gradualRow(kT, naturalAt - 120, 2, 'sent'),
        ],
        naturalFire(kT, naturalAt),
      ]);
      expect(o.exclusions, contains(WakeExclusion.competingAlarm));
    });

    test('a Gradual step that never landed is not a competing stimulus', () {
      final naturalAt = kT - 600;
      final o = run(trace: [
        [gradualRow(kT, kT - 900, 0, 'notDelivered')],
        naturalFire(kT, naturalAt),
      ]);
      expect(o.exclusions, isEmpty);
    });

    test('guard: Gradual over 15 min before the Natural fire does not exclude',
        () {
      final naturalAt = kT - 600;
      final o = run(trace: [
        [gradualRow(kT, naturalAt - 1000, 0, 'sent')],
        naturalFire(kT, naturalAt),
      ]);
      expect(o.exclusions, isNot(contains(WakeExclusion.competingAlarm)));
    });
  });

  group('phone-only stimuli before the band fire are competing (round 3, P2)',
      () {
    List<WakeTraceEntry> bandRepeat(int sec) => [
          row(kT, sec, 'natural_repeat', {
            'phase': 'result',
            'index': 1,
            'result': 'sent',
            'suppression': null,
            'error': null,
          }),
        ];

    test('phone at T-10 min, band repeat a minute later, response after: '
        'excluded', () {
      final phoneAt = kT - 600;
      final o = run(trace: [
        naturalFire(kT, phoneAt, targets: const ['phone']),
        bandRepeat(phoneAt + 60),
      ], move: [phoneAt + 90]);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
    });

    test('exactly 15 min before the band fire is inside, one second more is '
        'not', () {
      final bandAt = kT - 600;
      final inside = run(trace: [
        naturalFire(kT, bandAt - 900, targets: const ['phone']),
        bandRepeat(bandAt),
      ]);
      expect(inside.exclusions, [WakeExclusion.competingAlarm]);
      final outside = run(trace: [
        naturalFire(kT, bandAt - 901, targets: const ['phone']),
        bandRepeat(bandAt),
      ]);
      expect(outside.exclusions, isEmpty);
    });

    test('a phone-only attempt that did not sound anywhere is not a stimulus',
        () {
      final o = run(trace: [
        naturalNotDelivered(kT, kT - 660),
        bandRepeat(kT - 600),
      ]);
      expect(o.delivered, isTrue);
      expect(o.exclusions, isEmpty);
    });

    test('a phone-only Gradual step before the first band Gradual step is '
        'competing', () {
      final o = run(trace: [
        [
          gradualRow(kT, kT - 600, 0, 'sent', targets: const ['phone']),
          gradualRow(kT, kT - 540, 1, 'sent'),
        ],
      ]);
      expect(o.firedBy, WakeFiredBy.gradual);
      expect(o.firedAtSec, kT - 540);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
    });

    test('a phone-only Natural stimulus before the native alarm at T is '
        'competing', () {
      final o = run(trace: [
        naturalFire(kT, kT - 300, targets: const ['phone']),
        [fallbackRow(kT, kT - 7200), closedRow(kT, kT + 60)],
      ]);
      expect(o.firedBy, WakeFiredBy.native);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
    });

    test('guard: a single band+phone fire is not its own competitor', () {
      final o = run(trace: [
        naturalFire(kT, fire, targets: const ['phone', 'band']),
      ]);
      expect(o.exclusions, isEmpty);
    });
  });

  group("this wake's own native alarm is not another alarm (round 3, P3)", () {
    List<WakeTraceEntry> nativeWake() =>
        [fallbackRow(kT, kT - 7200), closedRow(kT, kT + 60)];

    test('a band alarm-fired stamp a few seconds before T, native fire: kept',
        () {
      final o = run(trace: [nativeWake()], others: [kT - 3]);
      expect(o.firedBy, WakeFiredBy.native);
      expect(o.exclusions, isEmpty);
    });

    test('an alarm-fired stamp at T or just after, any fire: no exclusion', () {
      for (final other in [kT, kT + 2, kT + 60]) {
        expect(run(trace: [naturalFire(kT, fire)], others: [other]).exclusions,
            isEmpty);
        expect(run(trace: [nativeWake()], others: [other]).exclusions, isEmpty);
      }
    });

    test('a different alarm 10 min before the native alarm at T still '
        'excludes', () {
      final o = run(trace: [nativeWake()], others: [kT - 600]);
      expect(o.exclusions, [WakeExclusion.competingAlarm]);
    });

    test('the slack is exactly 120 s around T', () {
      expect(run(trace: [nativeWake()], others: [kT - 120]).exclusions,
          isEmpty);
      expect(run(trace: [nativeWake()], others: [kT - 121]).exclusions,
          [WakeExclusion.competingAlarm]);
    });
  });

  group('the configured Natural window is recorded (P2)', () {
    test('the plan row naturalMinutes becomes configuredWindowMinutes', () {
      final o = run(trace: [
        [planRow(kT, kT - 3 * 3600, naturalMinutes: 45)],
        naturalFire(kT, kT - 20 * 60), // fired 20 min early under a 45 window
      ]);
      expect(o.toJson()['configuredWindowMinutes'], 45);
      expect(o.minutesBeforeT, 20.0, reason: 'firing time stays separate');
    });

    test('no plan row: the configured window is unknown (null)', () {
      final o = run(trace: [naturalFire(kT, fire)]);
      expect(o.toJson()['configuredWindowMinutes'], isNull);
    });

    test('configuredWindowMinutes survives the json round trip', () {
      final o = WakeOutcome.fromJson(jsonRoundTrip({
        ...run(trace: [naturalFire(kT, fire)]).toJson(),
        'configuredWindowMinutes': 45,
      }));
      expect(o.toJson()['configuredWindowMinutes'], 45);
      // Old stored outcomes have no such key and must still load, as null.
      final legacy = run(trace: [naturalFire(kT, fire)]).toJson()
        ..remove('configuredWindowMinutes');
      expect(WakeOutcome.fromJson(jsonRoundTrip(legacy)).toJson()['configuredWindowMinutes'],
          isNull);
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
