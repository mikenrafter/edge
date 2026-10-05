// A bounded memo of decoded day_result bundles in the read seam.
//
// Today every read decodes the payload again (SeriesCodec.decodePayloadJson on
// the main isolate): `_latestBundleAt` up to 14, Sleep detail twice for one
// night (getDaySleepV2 + getDayTimeline), Circadian ~49 per open.
//
// API (lib/data/local_repository_impl.dart; static, because `_decode`
// is static and the memo is shared by every LocalRepositoryImpl in the process:
// the warmer's, the background task's, the screens'):
//
//   @visibleForTesting static int debugBundleDecodes
//       Counts ACTUAL decodes of a day_result payload (a memo hit adds none).
//       Baselines / freshness / wake-feature decodes are not counted.
//   @visibleForTesting static int get debugBundleMemoLength
//   @visibleForTesting static void debugResetBundleMemo()
//       Empties the memo and zeroes the counter (test isolation).
//   static void invalidateBundleMemo()
//       Empties the memo. The DeriveCoordinator publish (`_publishDay`, and the
//       end-of-pass publish in afterDrain) calls it.
//
//   The memo is an LRU of 32 entries keyed by (day_id, algo_version,
//   computed_at) of the row the read actually got, so a re-derive (new
//   computed_at) or a newer algo version can never serve an older decode. A
//   `LocalDb.wipeAll()` (a new `LocalDb.wipeEpoch`) drops it too: the row it
//   described is gone and a re-seeded one may carry the same key.
//
//   A caller that mutates what it was handed must not change what the next
//   read gets (the memo hands out a deep copy, or the readers copy what they
//   expose).
//
//   A write the frozen-row guard REFUSES (a frozen finalized row) changes nothing, so
//   it must not invalidate: the memo keeps its entries and the next read is a
//   hit.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/last_result_db.dart';

const _db = 'bundle_memo_test.db';

/// Fixed so "new computed_at" is decided without a clock or a sleep.
const _seedAt = 1000;

String _day(int i) => DateTime(2025, 1, 1 + i).toIso8601String().substring(0, 10);

String _payload(String day, double rmssd) => jsonEncode({
      'date': day,
      'scalars': {'rmssd': rmssd},
      'series': {
        'hrv_timeline': [
          {'t': 1700000000, 'v': 40.0},
          {'t': 1700000300, 'v': 42.0},
        ],
        'hr_curve': [
          {'t': 1700000000, 'v': 60},
        ],
      },
    });

Future<void> _seed(String day,
    {double rmssd = 55,
    int version = kAlgoVersion,
    int computedAt = _seedAt,
    bool finalized = false}) async {
  final db = await LocalDb.instance;
  await db.insert(
      'day_result',
      {
        'day_id': day,
        'algo_version': version,
        'payload_json': _payload(day, rmssd),
        'window_json': '{}',
        'computed_at': computedAt,
        'finalized': finalized ? 1 : 0,
        'skipped': 0,
        'partial': 0,
        'rmssd': rmssd,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<num?> _rmssd(LocalRepositoryImpl r, String day) async =>
    (await r.getDayHrv(day))['rmssd'] as num?;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await g1FreshDb(_db);
    await LocalDb.instance;
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    LocalRepositoryImpl.debugResetBundleMemo();
  });
  tearDownAll(() => g1DropDb(_db));

  test('a miss decodes once; every later read of the same row is a hit',
      () async {
    await _seed(_day(0));
    expect(LocalRepositoryImpl.debugBundleDecodes, 0);

    expect(await _rmssd(repo, _day(0)), 55);
    expect(LocalRepositoryImpl.debugBundleDecodes, 1, reason: 'the miss');

    for (var i = 0; i < 3; i++) {
      expect(await _rmssd(repo, _day(0)), 55);
    }
    expect(LocalRepositoryImpl.debugBundleDecodes, 1, reason: 'hits decode '
        'nothing');
    expect(LocalRepositoryImpl.debugBundleMemoLength, 1);
  });

  test('Sleep detail\'s double read of one night decodes once '
      '(getDaySleepV2 + getDayTimeline)', () async {
    await _seed(_day(0));
    await repo.getDaySleepV2(_day(0));
    await repo.getDayTimeline(_day(0));
    expect(LocalRepositoryImpl.debugBundleDecodes, 1);
  });

  test('the latest-bundle walk (today with no row of its own) is memoised',
      () async {
    // Three past days and none for today: the walk decodes each (none has a
    // sleep, so it does not stop early) the first time, and nothing after.
    for (var i = 1; i <= 3; i++) {
      await _seed(_day(i));
    }
    final today = todayLabel();
    await repo.getDayHrv(today);
    final first = LocalRepositoryImpl.debugBundleDecodes;
    expect(first, greaterThanOrEqualTo(1));
    await repo.getDayHrv(today);
    await repo.getDayHrv(today);
    expect(LocalRepositoryImpl.debugBundleDecodes, first,
        reason: 'the second and third walks decode nothing');
  });

  test('a re-derive (new computed_at) is a miss and serves the NEW payload',
      () async {
    await _seed(_day(0), rmssd: 55);
    expect(await _rmssd(repo, _day(0)), 55);
    expect(LocalRepositoryImpl.debugBundleDecodes, 1);

    await _seed(_day(0), rmssd: 61, computedAt: _seedAt + 5000);
    expect(await _rmssd(repo, _day(0)), 61,
        reason: 'never the older decode of a replaced row');
    expect(LocalRepositoryImpl.debugBundleDecodes, 2);
    expect(await _rmssd(repo, _day(0)), 61);
    expect(LocalRepositoryImpl.debugBundleDecodes, 2, reason: 'and now a hit');
  });

  test('the algo version is part of the key: a newer-version sibling row is '
      'never answered from the older decode', () async {
    await _seed(_day(0), rmssd: 40, version: kAlgoVersion - 1);
    expect(await _rmssd(repo, _day(0)), 40);
    // Same computed_at on purpose: only the version differs.
    await _seed(_day(0), rmssd: 70, version: kAlgoVersion);
    expect(await _rmssd(repo, _day(0)), 70);
  });

  test('a publish invalidates', () async {
    await _seed(_day(0));
    await _rmssd(repo, _day(0));
    expect(LocalRepositoryImpl.debugBundleMemoLength, 1);

    LocalRepositoryImpl.invalidateBundleMemo();
    expect(LocalRepositoryImpl.debugBundleMemoLength, 0);

    await _rmssd(repo, _day(0));
    expect(LocalRepositoryImpl.debugBundleDecodes, 2,
        reason: 'decoded again after the publish');
  });

  test('the publish path is wired to it (DeriveCoordinator)', () {
    // `_publishDay` is private and driven by a timer-coalesced pass; the wiring
    // is pinned structurally, the behaviour above.
    final src = _read('lib/state/derive_coordinator.dart');
    final publish = _bodyAfter(src, 'void _publishDay()');
    expect(publish, contains('invalidateBundleMemo'),
        reason: 'the per-day publish drops the memo before screens re-read');
    expect('invalidateBundleMemo'.allMatches(src).length, greaterThanOrEqualTo(2),
        reason: 'the end-of-pass publish (afterDrain) drops it too');
  });

  test('never more than 32 entries; least recently used goes first',
      () async {
    for (var i = 0; i < 40; i++) {
      await _seed(_day(i));
    }
    for (var i = 0; i < 32; i++) {
      await _rmssd(repo, _day(i));
    }
    expect(LocalRepositoryImpl.debugBundleMemoLength, 32);
    expect(LocalRepositoryImpl.debugBundleDecodes, 32);

    await _rmssd(repo, _day(0)); // hit: day 0 is now the most recent
    expect(LocalRepositoryImpl.debugBundleDecodes, 32);

    await _rmssd(repo, _day(32)); // the 33rd: evicts the LEAST recent (day 1)
    expect(LocalRepositoryImpl.debugBundleDecodes, 33);
    expect(LocalRepositoryImpl.debugBundleMemoLength, 32);

    await _rmssd(repo, _day(0)); // kept
    expect(LocalRepositoryImpl.debugBundleDecodes, 33, reason: 'day 0 survived');
    await _rmssd(repo, _day(1)); // evicted
    expect(LocalRepositoryImpl.debugBundleDecodes, 34, reason: 'day 1 went');
    expect(LocalRepositoryImpl.debugBundleMemoLength, 32);

    for (var i = 0; i < 40; i++) {
      await _rmssd(repo, _day(i));
      expect(LocalRepositoryImpl.debugBundleMemoLength, lessThanOrEqualTo(32));
    }
  });

  test('a refused frozen write does not invalidate', () async {
    await _seed(_day(0), rmssd: 55, finalized: true);
    expect(await _rmssd(repo, _day(0)), 55);
    expect(LocalRepositoryImpl.debugBundleMemoLength, 1);

    // Frozen-row guard: a derive over a finalized (day, version) row is refused, no throw.
    await LocalDb.putDayResult(
      dayId: _day(0),
      algoVersion: kAlgoVersion,
      payloadJson: _payload(_day(0), 99),
      windowJson: '{}',
      rmssd: 99,
    );
    expect((await LocalDb.dayResult(_day(0)))!['computed_at'], _seedAt,
        reason: 'the guard refused it');

    expect(LocalRepositoryImpl.debugBundleMemoLength, 1,
        reason: 'nothing changed, so nothing is dropped');
    expect(await _rmssd(repo, _day(0)), 55);
    expect(LocalRepositoryImpl.debugBundleDecodes, 1, reason: 'still a hit');
  });

  test('an accepted override write over a frozen row IS a miss with the new '
      'payload', () async {
    await _seed(_day(0), rmssd: 55, finalized: true);
    await _rmssd(repo, _day(0));
    await LocalDb.putDayResult(
      dayId: _day(0),
      algoVersion: kAlgoVersion,
      payloadJson: _payload(_day(0), 72),
      windowJson: '{}',
      rmssd: 72,
      reason: DayResultWrite.userOverride,
    );
    expect(await _rmssd(repo, _day(0)), 72);
    expect(LocalRepositoryImpl.debugBundleDecodes, 2);
  });

  test('a wipe drops the memo: a re-seeded row with the very same key is '
      'not answered from the old decode', () async {
    await _seed(_day(0), rmssd: 55);
    expect(await _rmssd(repo, _day(0)), 55);

    await LocalDb.wipeAll();
    await _seed(_day(0), rmssd: 80); // same day, version AND computed_at
    expect(await _rmssd(repo, _day(0)), 80);
  });

  test('mutating what a read returned does not change the next read',
      () async {
    await _seed(_day(0));
    final a = await repo.getDayHrv(_day(0));
    (a['timeline'] as List).clear();
    a['rmssd'] = -1;

    final b = await repo.getDayHrv(_day(0));
    expect((b['timeline'] as List), hasLength(2),
        reason: 'the memo is not handed out by reference');
    expect(b['rmssd'], 55);
  });
}

String _read(String path) => File(path).readAsStringSync();

/// The text from [marker] to the end of the method body that starts there.
String _bodyAfter(String src, String marker) {
  final at = src.indexOf(marker);
  expect(at, isNonNegative, reason: '$marker exists');
  var depth = 0, i = src.indexOf('{', at);
  final start = i;
  for (; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) break;
  }
  return src.substring(start, i + 1);
}
