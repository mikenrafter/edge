// worker_init_test.dart — WorkerInit / assertWorker / the markers and RowBatch
// (design 02: "WorkerInit.ensure(inputs) explicit worker init (clock/zone/
// locale as PLAIN inputs; re-arms analytics ambient globals) + assertWorker()
// (debug)", rev 3 item 6, "Ambient-global test").
//

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/util/heavy.dart';
import 'package:openstrap_edge/util/raw_readers.dart';
import 'package:openstrap_edge/util/worker_init.dart';

// Top-level so the Isolate.run closures below capture only sendable values.
const _inputsCold = WorkerInputs(nowEpochMs: 1, zoneId: 'UTC', localeTag: 'en');

String _profileJson(int nights) =>
    jsonEncode(ana.SleepUserProfile(nights: nights, updatedAtMs: 5).toJson());

void main() {
  // The analytics globals must be left as we found them.
  tearDown(() {
    ana.cardioUserProfile = null;
    ana.cardioRecordObservations = false;
    ana.resetCardioObservations();
  });

  group('WorkerInit.ensure re-arms the analytics ambient globals', () {
    // The main isolate of the test process must look like "not a worker".
    setUp(() => WorkerInit.resetForTest());

    test('profile and recording flag are set INSIDE the worker from plain inputs',
        () async {
      final profile = _profileJson(7);
      final seen = await Isolate.run(() {
        WorkerInit.ensure(WorkerInputs(
          nowEpochMs: 1,
          zoneId: 'UTC',
          localeTag: 'en',
          sleepProfileJson: profile,
          recordSleepObservations: true,
        ));
        return (ana.cardioUserProfile?.nights, ana.cardioRecordObservations);
      });
      expect(seen, (7, true));
    });

    test('globals set on the main isolate are not inherited; ensure decides',
        () async {
      ana.cardioUserProfile = const ana.SleepUserProfile(nights: 99);
      ana.cardioRecordObservations = true;
      final seen = await Isolate.run(() {
        WorkerInit.ensure(_inputsCold);
        return (ana.cardioUserProfile?.nights, ana.cardioRecordObservations);
      });
      expect(seen, (null, false),
          reason: 'cold start inputs mean cold start in the worker');
    });

    test('a second ensure replaces, not merges, the previous arming', () async {
      final p3 = _profileJson(3);
      final seen = await Isolate.run(() {
        WorkerInit.ensure(WorkerInputs(
            nowEpochMs: 1, zoneId: 'UTC', localeTag: 'en', sleepProfileJson: p3));
        final first = ana.cardioUserProfile?.nights;
        WorkerInit.ensure(_inputsCold);
        return (first, ana.cardioUserProfile?.nights);
      });
      expect(seen, (3, null));
    });

    test('ensure is idempotent for the same inputs', () async {
      final p = _profileJson(4);
      final seen = await Isolate.run(() {
        final inputs = WorkerInputs(
            nowEpochMs: 1, zoneId: 'UTC', localeTag: 'en', sleepProfileJson: p);
        WorkerInit.ensure(inputs);
        final a = ana.cardioUserProfile?.nights;
        WorkerInit.ensure(inputs);
        return (a, ana.cardioUserProfile?.nights);
      });
      expect(seen, (4, 4));
    });
  });

  group('assertWorker (debug)', () {
    setUp(() => WorkerInit.resetForTest());

    test('trips on the main isolate before any ensure', () {
      expect(WorkerInit.isInitialised, isFalse);
      expect(assertWorker, throwsA(isA<AssertionError>()));
    });

    test('passes in the same isolate after ensure', () {
      WorkerInit.ensure(_inputsCold);
      expect(WorkerInit.isInitialised, isTrue);
      expect(assertWorker, returnsNormally);
    });

    test('a fresh isolate is NOT a worker until ensure ran there', () async {
      // No reliance on Isolate.debugName or on "being in an isolate".
      final verdict = await Isolate.run(() {
        try {
          assertWorker();
          return 'passed';
        } on AssertionError {
          return 'tripped';
        }
      });
      expect(verdict, 'tripped');
    });

    test('ensure in the worker is what makes assertWorker pass there', () async {
      final verdict = await Isolate.run(() {
        WorkerInit.ensure(_inputsCold);
        try {
          assertWorker();
          return 'passed';
        } on AssertionError {
          return 'tripped';
        }
      });
      expect(verdict, 'passed');
    });

    test('resetForTest puts the isolate back to "not a worker"', () {
      WorkerInit.ensure(_inputsCold);
      WorkerInit.resetForTest();
      expect(WorkerInit.isInitialised, isFalse);
    });
  });

  group('WorkerInputs are plain data', () {
    test('clock, zone and locale are fields, not ambient reads', () {
      const i = WorkerInputs(nowEpochMs: 42, zoneId: 'Europe/Berlin', localeTag: 'de');
      expect((i.nowEpochMs, i.zoneId, i.localeTag), (42, 'Europe/Berlin', 'de'));
      expect(i.sleepProfileJson, isNull);
      expect(i.recordSleepObservations, isFalse);
    });
  });

  group('RowBatch', () {
    test('wrap is an unmodifiable snapshot of the rows', () {
      final src = <Map<String, Object?>>[
        {'rec_ts': 1},
      ];
      final batch = RowBatch<Map<String, Object?>>.wrap(src);
      src.add({'rec_ts': 2});
      expect(batch.length, 1, reason: 'later edits to the source are not seen');
      final asList = (batch as Object) as List<Map<String, Object?>>;
      expect(() => asList.add({'rec_ts': 3}), throwsUnsupportedError);
    });

    test('wrapping an empty list is an empty batch', () {
      expect(RowBatch<Map<String, Object?>>.wrap(const []).isEmpty, isTrue);
    });
  });

  group('markers', () {
    test('are const and carry their reason', () {
      expect(identical(heavy, const Heavy()), isTrue);
      expect(identical(live, const Live()), isTrue);
      expect(identical(sendable, const Sendable()), isTrue);
      expect(const SendableShape('stored payload').reason, 'stored payload');
    });
  });
}
