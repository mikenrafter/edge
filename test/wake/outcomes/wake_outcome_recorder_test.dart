// The shadow-mode wiring behind AppState, driven through its injected seams:
// gated off writes nothing; a closed wake becomes one stored outcome whose
// rating survives a re-run; the foreground catch-up picks the newest wake that
// is 2..12 h old; the Home prompt is the newest delivered, unrated outcome
// under 12 h old.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_recorder.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_store.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

import 'outcome_rig.dart';

class _Rig {
  _Rig({this.on = true}) {
    store = WakeOutcomeStore(
      read: (k) async => kv[k],
      write: (k, v) async {
        writes++;
        kv[k] = v;
      },
    );
    recorder = WakeOutcomeRecorder(
      enabled: () => on,
      store: store,
      traceFor: (t) async => [
        for (final r in trace)
          if (r.wakeEpochSec == t) r,
      ],
      recentTrace: () async => trace,
      evidenceFor: (_) async => evidence,
      // Additive rig change (not an encoded defect): the in-memory foreground
      // touch buffer, which expires after five minutes in the app.
      touchSecs: () => touches,
      now: () => DateTime.fromMillisecondsSinceEpoch(nowSec * 1000, isUtc: true),
    );
  }

  bool on;
  int nowSec = kT + 3 * 3600;
  int writes = 0;
  final kv = <String, String>{};
  final trace = <WakeTraceEntry>[];
  final touches = <int>[];
  WakeEvidenceSecs evidence = (appOpened: <int>[], movement: <int>[]);
  late final WakeOutcomeStore store;
  late final WakeOutcomeRecorder recorder;
}

/// A Natural fire 20 minutes early, then the close at T.
List<WakeTraceEntry> _closedNaturalWake(int wake) => [
      ...naturalFire(wake, wake - 20 * 60),
      closedRow(wake, wake + 1),
    ];

void main() {
  group('gate', () {
    test('off: nothing is read into a write, nothing is stored', () async {
      final rig = _Rig(on: false)..trace.addAll(_closedNaturalWake(kT));
      expect(await rig.recorder.record(kT), isNull);
      expect(await rig.recorder.catchUp(), isNull);
      expect(await rig.recorder.pendingRating(), isNull);
      expect(await rig.recorder.rate(kT, 3), isFalse);
      expect(await rig.recorder.outcomes(), isEmpty);
      expect(rig.writes, 0);
      expect(rig.kv, isEmpty);
    });
  });

  group('record', () {
    test('a closed wake becomes one stored outcome', () async {
      final rig = _Rig()
        ..trace.addAll(_closedNaturalWake(kT))
        ..evidence = (appOpened: [kT - 20 * 60 + 90], movement: <int>[]);
      final outcome = await rig.recorder.record(kT);
      expect(outcome, isNotNull);
      expect(outcome!.firedBy, WakeFiredBy.natural);
      expect(outcome.delivered, isTrue);
      expect(outcome.latencySec[WakeResponseKind.appInteraction], 90);
      // Movement was not seen: unknown, never 0.
      expect(outcome.latencySec[WakeResponseKind.movement], isNull);
      final stored = await rig.store.load();
      expect(stored, hasLength(1));
      expect(stored.single.wakeSec, kT);
    });

    test('running it again replaces the outcome and keeps the rating',
        () async {
      final rig = _Rig()..trace.addAll(_closedNaturalWake(kT));
      await rig.recorder.record(kT);
      expect(await rig.recorder.rate(kT, 4), isTrue);
      rig.evidence = (appOpened: <int>[], movement: [kT - 20 * 60 + 60]);
      await rig.recorder.record(kT);
      final stored = await rig.store.load();
      expect(stored, hasLength(1));
      expect(stored.single.grogginess, 4);
      expect(stored.single.latencySec[WakeResponseKind.movement], 60,
          reason: 'the second run saw more and replaced the first');
    });

    test('no fire and no close in the trace: no outcome (what reached the '
        'band is unknown)', () async {
      final rig = _Rig()
        ..trace.add(row(kT, kT - 3600, 'plan', {'configuration': 'natural'}));
      expect(await rig.recorder.record(kT), isNull);
      expect(rig.writes, 0);
    });

    test('a failing evidence read never throws and writes nothing', () async {
      final rig = _Rig()..trace.addAll(_closedNaturalWake(kT));
      final recorder = WakeOutcomeRecorder(
        enabled: () => true,
        store: rig.store,
        traceFor: (_) async => rig.trace,
        recentTrace: () async => rig.trace,
        evidenceFor: (_) async => throw StateError('db closed'),
      );
      expect(await recorder.record(kT), isNull);
      expect(rig.writes, 0);
    });
  });

  group('re-recording keeps what was already observed (P2)', () {
    const fire = kT - 20 * 60; // _closedNaturalWake fires 20 min before T

    test('a response from the touch buffer survives the catch-up after the '
        'buffer expired', () async {
      final rig = _Rig()
        ..trace.addAll(_closedNaturalWake(kT))
        ..nowSec = kT + 60
        ..touches.add(fire + 90);
      final first = await rig.recorder.record(kT);
      expect(first!.latencySec[WakeResponseKind.appInteraction], 90);

      // Five minutes later the buffer is empty and the persisted evidence has
      // nothing for this wake.
      rig.touches.clear();
      rig.nowSec = kT + 3 * 3600;
      await rig.recorder.catchUp();

      final stored = (await rig.store.load()).single;
      expect(stored.latencySec[WakeResponseKind.appInteraction], 90,
          reason: 'null would mean "not observed", erasing a seen response');
    });

    test('an already-awake exclusion survives the catch-up', () async {
      final rig = _Rig()
        ..trace.addAll(_closedNaturalWake(kT))
        ..nowSec = kT + 60
        ..touches.add(fire - 300);
      final first = await rig.recorder.record(kT);
      expect(first!.exclusions, [WakeExclusion.alreadyAwake]);

      rig.touches.clear();
      rig.nowSec = kT + 3 * 3600;
      await rig.recorder.catchUp();

      final stored = (await rig.store.load()).single;
      expect(stored.exclusions, [WakeExclusion.alreadyAwake]);
      expect(stored.usable, isFalse,
          reason: 'the morning must not become comparable again');
    });

    test('the earliest observed latency wins, in either order', () async {
      final rig = _Rig()..trace.addAll(_closedNaturalWake(kT));
      rig.evidence = (appOpened: <int>[], movement: [fire + 300]);
      await rig.recorder.record(kT);
      rig.evidence = (appOpened: <int>[], movement: [fire + 120]);
      await rig.recorder.record(kT);
      expect((await rig.store.load()).single
              .latencySec[WakeResponseKind.movement],
          120);
      // A later run that only sees a later movement must not push it back.
      rig.evidence = (appOpened: <int>[], movement: [fire + 500]);
      await rig.recorder.record(kT);
      expect((await rig.store.load()).single
              .latencySec[WakeResponseKind.movement],
          120);
    });

    test('a Gradual step before the Natural fire is supplied as a competing '
        'stimulus', () async {
      final naturalAt = kT - 600;
      final rig = _Rig()
        ..trace.addAll([
          gradualRow(kT, kT - 900, 0, 'sent'),
          ...naturalFire(kT, naturalAt),
          closedRow(kT, kT + 1),
        ]);
      final outcome = await rig.recorder.record(kT);
      expect(outcome!.exclusions, contains(WakeExclusion.competingAlarm));
      expect((await rig.store.load()).single.usable, isFalse);
    });

    test('the configured window of the night is stored', () async {
      final rig = _Rig()
        ..trace.addAll([
          planRow(kT, kT - 3 * 3600, naturalMinutes: 45),
          ..._closedNaturalWake(kT),
        ]);
      final outcome = await rig.recorder.record(kT);
      expect(outcome!.toJson()['configuredWindowMinutes'], 45);
      expect((await rig.store.load()).single.toJson()['configuredWindowMinutes'],
          45);
    });
  });

  group('catchUp', () {
    test('picks the newest wake that is 2..12 h old', () async {
      final rig = _Rig()..nowSec = kT + 3 * 3600;
      rig.trace
        ..addAll(_closedNaturalWake(kT - 86400)) // a day old: out of range
        ..addAll(_closedNaturalWake(kT)) // 3 h old: the one
        ..addAll(_closedNaturalWake(kT + 2 * 3600 + 60)); // under 2 h old
      final outcome = await rig.recorder.catchUp();
      expect(outcome!.wakeSec, kT);
      expect((await rig.store.load()).map((o) => o.wakeSec), [kT]);
    });

    test('a catch-up after the closed tick keeps the rating', () async {
      final rig = _Rig()..trace.addAll(_closedNaturalWake(kT));
      rig.nowSec = kT + 60;
      await rig.recorder.record(kT);
      await rig.recorder.rate(kT, 5);
      rig.nowSec = kT + 3 * 3600;
      await rig.recorder.catchUp();
      final stored = await rig.store.load();
      expect(stored, hasLength(1));
      expect(stored.single.grogginess, 5);
    });

    test('nothing in range: nothing stored', () async {
      final rig = _Rig()
        ..nowSec = kT + 20 * 3600
        ..trace.addAll(_closedNaturalWake(kT));
      expect(await rig.recorder.catchUp(), isNull);
      expect(rig.writes, 0);
    });
  });

  group('pendingRating', () {
    test('the newest delivered, unrated outcome under 12 h old', () async {
      final rig = _Rig()
        ..trace.addAll(_closedNaturalWake(kT))
        ..nowSec = kT + 3600;
      await rig.recorder.record(kT);
      expect((await rig.recorder.pendingRating())!.wakeSec, kT);

      await rig.recorder.rate(kT, 2);
      expect(await rig.recorder.pendingRating(), isNull);
    });

    test('older than 12 h: no prompt', () async {
      final rig = _Rig()..trace.addAll(_closedNaturalWake(kT));
      rig.nowSec = kT + 3600;
      await rig.recorder.record(kT);
      rig.nowSec = kT + 13 * 3600;
      expect(await rig.recorder.pendingRating(), isNull);
    });

    test('an undelivered wake is not asked about', () async {
      final rig = _Rig()
        ..trace.addAll([
          ...naturalNotDelivered(kT, kT - 20 * 60),
          closedRow(kT, kT + 1),
          fallbackRow(kT, kT - 600, armed: false, confirmed: false),
        ])
        ..nowSec = kT + 3600;
      final outcome = await rig.recorder.record(kT);
      expect(outcome!.delivered, isFalse);
      expect(await rig.recorder.pendingRating(), isNull);
    });
  });
}
