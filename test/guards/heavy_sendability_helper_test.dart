// heavy_sendability_helper_test.dart — the round-trip helper behind "each
// worker entry's argument and result types are sent through a real
// Isolate.run round trip" (design 02, runtime tests). Real isolates, no fakes.
//
// They exist so the helper cannot rot before the per-entry tests that depend
// on it land.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'support/entry_samples.dart';
import 'support/sendability.dart';

void main() {
  group('isolateRoundTrip (real Isolate.run)', () {
    test('the closed grammar survives both directions', () async {
      await expectIsolateRoundTrip<Object?>(null);
      await expectIsolateRoundTrip<Object?>(true);
      await expectIsolateRoundTrip<Object?>(7);
      await expectIsolateRoundTrip<Object?>(1.5);
      await expectIsolateRoundTrip<Object?>('s');
      await expectIsolateRoundTrip<Object?>(Uint8List.fromList([1, 2, 3]));
      await expectIsolateRoundTrip<Object?>(Float64List.fromList([1.5, 2.5]));
      await expectIsolateRoundTrip<Object?>(Int32List.fromList([1, 2]));
      await expectIsolateRoundTrip<Object?>(<double>[1, 2, 3]);
      await expectIsolateRoundTrip<Object?>(<String, List<int>>{'a': [1]});
      await expectIsolateRoundTrip<Object?>((1, 'two', [3.0]));
    });

    test('a value class with sendable fields survives (WorkerInputs)', () async {
      const inputs = WorkerInputs(
        nowEpochMs: 1,
        zoneId: 'UTC',
        localeTag: 'en',
        sleepProfileJson: '{"nights":3}',
        recordSleepObservations: true,
      );
      await expectIsolateRoundTrip<WorkerInputs>(
        inputs,
        project: (i) => (
          i.nowEpochMs,
          i.zoneId,
          i.localeTag,
          i.sleepProfileJson,
          i.recordSleepObservations,
        ),
      );
    });

    test('the copy is a different object (it really crossed)', () async {
      final list = <int>[1, 2, 3];
      final copy = await isolateRoundTrip(list);
      expect(identical(copy, list), isFalse);
      expect(copy, list);
    });

    test('a value holding a ReceivePort is reported as not sendable', () async {
      final rp = ReceivePort();
      addTearDown(rp.close);
      expect(await isNotSendable(rp), isTrue);
      expect(await isNotSendable(<String, Object?>{'port': rp}), isTrue);
      expect(await isNotSendable(<int>[1, 2]), isFalse);
    });

    test('a changed value after the trip fails the helper', () {
      expect(
        () => expectIsolateRoundTrip<List<int>>(
          [1, 2],
          project: (l) => _Counter.tick(), // differs on every call
        ),
        throwsStateError,
      );
    });
  });

  group('registered entries', () {
    test('every kWorkerEntries symbol has a round-trip sample', () {
      final missing = [
        for (final e in kWorkerEntries)
          if (!kEntrySamples.containsKey(e.symbol)) e.symbol,
      ];
      expect(missing, isEmpty,
          reason: 'add the entry to test/guards/support/entry_samples.dart');
    });

    for (final e in kWorkerEntries) {
      test('${e.symbol}: argument and result cross a real isolate', () async {
        final sample = kEntrySamples[e.symbol]!;
        await sample.roundTrip();
      });
    }
  });
}

/// A value that is different every time it is projected, so the helper's two
/// projections (before/after the trip) never match.
class _Counter {
  static int _n = 0;
  static Object tick() => _n++;
}
