// P2.2 fix round 2 (Sol r2): admission is an atomic reservation.
//
// A request is admitted when its source bytes are RESERVED against the budget
// in the same synchronous step as the capacity check; the reservation turns
// into queue accounting when the flight is enqueued and is released on every
// other exit. Source text is not held while waiting for room.
//
//   (a) another reader takes capacity while readAll reads its chunk-boundary
//       payload: the walk's admitted members count, existing flights finish,
//       and the new batch waits and then completes;
//   (b) running + queued + reserved source bytes never pass the 4 MB budget;
//   (c) reservations are released on error, refusal, stale and invalidation
//       paths: the reserved count returns to zero.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p22_support.dart';

const _name = 'p22_fix_round2.db';
const _mb = 1024 * 1024;

String _d(int i) => DateTime.utc(2025, 1, 1 + i).toIso8601String().substring(0, 10);

String _padded(String tag, int bytes) => jsonEncode({'tag': tag, 'pad': 'x' * bytes});

/// Runs the registered action for a source when its payload is about to be read.
final class _AtRead implements BundleReadProbe {
  final Map<String, Future<void> Function()> actions = {};
  @override
  Future<void> afterMeta(BundleSource source) async {
    await actions.remove(source.k1)?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P22Lane lane;
  late BundleStore store;
  late _AtRead probe;

  Future<void> raw(int i, String tag, int bytes) =>
      p21RawDay(db, _d(i), version: p21Version, payload: _padded(tag, bytes));

  setUp(() async {
    db = await p21Fresh(_name);
    lane = P22Lane();
    probe = _AtRead();
    store = p22Store(lane, queueWait: const Duration(seconds: 5))..debugProbe = probe;
  });
  tearDown(() => p21Drop(_name));

  void expectNothingHeld() {
    expect(store.debugReservedBytes, 0, reason: 'reserved bytes leaked');
    expect(store.debugReservedRequests, 0, reason: 'reserved requests leaked');
    expect(store.debugSourceBytesHeld, 0);
    expect(store.debugFlightCount, 0);
  }

  group('(a) another reader takes capacity during the carry read', () {
    // m0 (3 MB) is admitted; the next payload does not fit its chunk, so it is
    // the carry. While the carry is being read, a 2 MB reader arrives.
    test('the admitted batch counts: a reader that does not fit is refused '
        'instead of overcommitting the budget', () async {
      await raw(0, 'm0', 3 * _mb);
      await raw(1, 'carry', 100 * 1024);
      await raw(2, 'other', 2 * _mb);
      store = p22Store(lane, queueWait: Duration.zero)..debugProbe = probe;
      lane.holdAll = true;
      Object? outcome;
      // The carry's read is held open until the other reader has been decided,
      // so the window between the walk's admission and its enqueue is the
      // only place the other reader can look at the budget.
      probe.actions[_d(1)] = () async {
        store.read(BundleSource.day(_d(2))).then<void>(
          (r) => outcome = r,
          onError: (Object e) => outcome = e,
        );
        await p22Until(() => outcome != null || store.debugFlightCount > 0,
            'the other reader is admitted or refused');
      };

      final walk = store.readAll([BundleSource.day(_d(0)), BundleSource.day(_d(1))]);

      await p22Until(() => outcome != null || lane.chunks.isNotEmpty, 'decided');
      expect(outcome, isA<BundleRetryable>(),
          reason: '3 MB are reserved; 2 more do not fit in 4 MB');
      lane.releaseAll();
      expect((await walk).map(p22TagOf).toList(), ['m0', 'carry']);
      expectNothingHeld();
    });

    test('a reader that fits keeps its capacity; the carry waits for room and '
        'completes; nobody is rejected', () async {
      await raw(0, 'm0', 3 * _mb);
      await raw(1, 'carry', 500 * 1024);
      await raw(2, 'other', 1 * _mb - 64 * 1024);
      lane.holdAll = true;
      Future<BundleRead>? other;
      probe.actions[_d(1)] = () => other = store.read(BundleSource.day(_d(2)));

      final walk = store.readAll([BundleSource.day(_d(0)), BundleSource.day(_d(1))]);
      await p22Until(() => other != null, 'the other reader started');
      await lane.arrived(1);
      expect(store.debugSourceBytesHeld, lessThanOrEqualTo(4 * _mb));
      lane.releaseAll();

      expect(p22TagOf(await other!), 'other');
      expect((await walk).map(p22TagOf).toList(), ['m0', 'carry']);
      expect(lane.payloads, 3, reason: 'every payload decoded once');
      expectNothingHeld();
    });
  });

  group('(b) held source bytes stay inside the budget', () {
    test('a walk of 1 MB payloads next to other readers never holds more than '
        '4 MB (running + queued + reserved)', () async {
      for (var i = 0; i < 6; i++) {
        await raw(i, 'w$i', _mb);
      }
      for (var i = 6; i < 9; i++) {
        await raw(i, 'o$i', _mb);
      }
      var peak = 0;
      void sample() {
        if (store.debugSourceBytesHeld > peak) peak = store.debugSourceBytesHeld;
      }

      lane.hook = (i, chunk) async => sample();
      for (var i = 0; i < 9; i++) {
        probe.actions[_d(i)] = () async => sample();
      }

      final walk = store.readAll([for (var i = 0; i < 6; i++) BundleSource.day(_d(i))]);
      final others = [for (var i = 6; i < 9; i++) store.read(BundleSource.day(_d(i)))];
      final out = await walk;
      await Future.wait(others);
      sample();

      expect(out.map(p22TagOf).toList(), [for (var i = 0; i < 6; i++) 'w$i']);
      expect(peak, lessThanOrEqualTo(BundleStore.maxSourceBytesInFlight),
          reason: 'a single payload over the budget cannot be admitted at all, '
              'so there is no oversize allowance');
      expectNothingHeld();
    });
  });

  group('(c) reservations are released on every exit', () {
    test('a member that cannot be admitted: the ones already reserved are '
        'released and no flight is left', () async {
      await raw(0, 'a', 3 * _mb);
      await raw(1, 'b', 2 * _mb);
      store = p22Store(lane, queueWait: Duration.zero)..debugProbe = probe;

      await expectLater(
        store.readAll([BundleSource.day(_d(0)), BundleSource.day(_d(1))], chunkRows: 8),
        throwsA(isA<BundleRetryable>()),
      );

      expect(store.debugReservedBytes, 0, reason: 'nothing is left reserved');
      expect(store.debugReservedRequests, 0);
      // The chunk queued before the carry was refused is a real flight: it runs
      // to completion and releases its own accounting.
      await p22Until(() => store.debugFlightCount == 0, 'the queued chunk finishes');
      expectNothingHeld();
    });

    test('readOnce refused for room: nothing stays reserved', () async {
      await raw(0, 'a', 3 * _mb);
      await raw(1, 'b', 2 * _mb);
      store = p22Store(lane, queueWait: Duration.zero)..debugProbe = probe;
      lane.holdAll = true;
      final first = store.read(BundleSource.day(_d(0)));
      await lane.arrived(1);

      await expectLater(store.read(BundleSource.day(_d(1))), throwsA(isA<BundleRetryable>()));
      expect(store.debugReservedBytes, 0);
      lane.releaseAll();
      await first;
      expectNothingHeld();
    });

    test('a lane that throws: reservations and accounting return to zero',
        () async {
      await p22Put(_d(0), 'a');
      await p22Put(_d(1), 'b');
      lane.hook = (i, c) async => throw StateError('boom');

      await expectLater(store.read(BundleSource.day(_d(0))), throwsA(isA<StateError>()));
      await expectLater(
        store.readAll([BundleSource.day(_d(1))]),
        throwsA(isA<StateError>()),
      );

      expectNothingHeld();
    });

    test('stale paths: a payload read that goes stale, and a completion the '
        'fence rejects', () async {
      await p22Put(_d(0), 'a');
      probe.actions[_d(0)] = () => p22Put(_d(0), 'b', reason: DayResultWrite.userOverride);
      expect(await store.readOnce(BundleSource.day(_d(0))), isA<BundleStale>());
      expectNothingHeld();

      lane.hook = (i, c) async {
        if (i == 0) await p22Put(_d(0), 'c', reason: DayResultWrite.userOverride);
      };
      expect(await store.readOnce(BundleSource.day(_d(0))), isA<BundleStale>());
      expectNothingHeld();
    });

    test('invalidateAll with queued and running flights: everything returns '
        'to zero once the lane is released', () async {
      for (var i = 0; i < 3; i++) {
        await raw(i, 't$i', 600 * 1024);
      }
      lane.holdAll = true;
      final reads = [
        store.read(BundleSource.day(_d(0))),
        store.readAll([BundleSource.day(_d(1)), BundleSource.day(_d(2))]),
      ];
      await lane.arrived(1);
      await p22Until(
        () => store.debugFlightCount == 2 && store.debugReservedRequests == 1,
        'one running, one queued, the walk\'s carry holding a reservation',
      );

      store.invalidateAll();
      lane.releaseAll();
      await Future.wait(reads);

      expectNothingHeld();
    });

    test('a reader that joins a flight started while it waited gives its '
        'reservation back', () async {
      await raw(0, 'a', 2 * _mb);
      await raw(1, 'b', 2 * _mb);
      lane.holdAll = true;

      final a = store.read(BundleSource.day(_d(0)));
      final a2 = store.read(BundleSource.day(_d(0)));
      final b = store.read(BundleSource.day(_d(1)));
      await lane.arrived(1);
      lane.releaseAll();

      expect(p22TagOf(await a), 'a');
      expect(p22TagOf(await a2), 'a');
      expect(p22TagOf(await b), 'b');
      expectNothingHeld();
    });
  });
}
