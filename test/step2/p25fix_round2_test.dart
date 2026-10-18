// P2.5 fix round 2 (Sol r2 = REVISE). All four: a wipe, delete or replace that
// lands while something is awaited must never let the old data come back.
//
//   1  decodeMany: a wipe during a later chunk makes the WHOLE answer absent,
//      and entries from cache hits / earlier chunks are re-read before return.
//   2  a row with no revision (not backfilled into row_rev) that is replaced
//      mid-decode is a change: the new value or absence, never the old one.
//   3  the Android export revalidates its retained priority bundle against
//      storage before reusing it: a re-derive rewrites that night's sleep, a
//      wipe aborts the pass.
//   4  LastResultCache.put fences its write-through against the generation: a
//      wipe during the worker encode leaves the table empty.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/p25_support.dart';

const _name = 'p25fix_round2.db';

class _JsonLane implements JsonPayloadDecodeLane {
  final calls = <JsonPayloadsInput>[];
  Future<void> Function(int index, JsonPayloadsInput input)? hook;

  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) async {
    final index = calls.length;
    calls.add(input);
    await hook?.call(index, input);
    return decodeJsonPayloadsHeavy(bundleWorkerInputs, input);
  }
}

class _Src implements JsonRowSource {
  _Src(this.key, this.row);
  @override
  final String key;
  JsonRowState? row;

  @override
  Future<JsonRowState?> current() async => row;
}

JsonRowState _row(int? rev, Object? value) =>
    JsonRowState(revision: rev, text: jsonEncode(value));

class _Android implements HealthExportPlatform {
  const _Android();
  @override
  bool get isAndroid => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
    await p21Drop(_name);
  });

  group('1: decodeMany is all-or-nothing across a wipe', () {
    late _JsonLane fake;
    late JsonPayloadLane lane;
    setUp(() {
      fake = _JsonLane();
      lane = JsonPayloadLane(lane: fake);
    });

    List<JsonLaneRow> windows(int n, List<_Src> into) => [
      for (var i = 0; i < n; i++)
        () {
          final src = _Src('window|$i', _row(1, {'onset_ms': i}));
          into.add(src);
          return (source: src, state: _row(1, {'onset_ms': i}));
        }(),
    ];

    test('a wipe during the SECOND chunk of fourteen cold windows: every '
        'entry is absent, including those the first chunk had filled', () async {
      final srcs = <_Src>[];
      final rows = windows(14, srcs);
      fake.hook = (i, _) async {
        if (i == 1) await LocalDb.wipeAll();
      };

      final out = await lane.decodeMany(rows);

      expect(fake.calls, hasLength(2), reason: 'guard: two chunks (8 + 6)');
      expect(out, hasLength(14));
      expect(out.every((r) => r == null), isTrue);
      expect(lane.debugEntries, 0, reason: 'chunk 1 was cached before the wipe '
          'only if it was published; it must not outlive the answer');
    });

    test('a cache hit is not exposed across a wipe either', () async {
      final srcs = <_Src>[];
      final rows = windows(10, srcs);
      await lane.decode(rows[0].source, rows[0].state); // row 0 is now a hit
      fake.calls.clear();
      fake.hook = (i, _) async {
        if (i == 0) await LocalDb.wipeAll();
      };

      final out = await lane.decodeMany(rows);

      expect(out.every((r) => r == null), isTrue);
    });

    test('a hit whose row is replaced while the misses are decoded is not '
        'returned; the others are', () async {
      final srcs = <_Src>[];
      final rows = windows(10, srcs);
      await lane.decode(rows[0].source, rows[0].state);
      fake.calls.clear();
      fake.hook = (i, _) async {
        if (i == 0) srcs[0].row = _row(2, {'onset_ms': 999});
      };

      final out = await lane.decodeMany(rows);

      expect(out[0], isNull, reason: 'its row moved after the hit was taken');
      expect(out.skip(1).every((r) => r != null), isTrue);
    });

    test('earlier-chunk entries are re-read: a row deleted during chunk 2 is '
        'absent', () async {
      final srcs = <_Src>[];
      final rows = windows(14, srcs);
      fake.hook = (i, _) async {
        if (i == 1) srcs[3].row = null; // in chunk 1, already "published"
      };

      final out = await lane.decodeMany(rows);

      expect(out[3], isNull);
      expect(out.where((r) => r != null), hasLength(13));
    });
  });

  group('2: a row with no revision', () {
    late _JsonLane fake;
    late JsonPayloadLane lane;
    setUp(() {
      fake = _JsonLane();
      lane = JsonPayloadLane(lane: fake);
    });

    test('replaced mid-decode (still no revision): the new value, not the old',
        () async {
      final src = _Src('legacy', _row(null, {'v': 'old'}));
      fake.hook = (i, _) async {
        if (i == 0) src.row = _row(null, {'v': 'new'});
      };

      final out = await lane.decode(src, _row(null, {'v': 'old'}));

      expect((out!.value as Map)['v'], 'new');
      expect(lane.debugEntries, 0, reason: 'no revision: never cached');
    });

    test('a row that GAINS a revision is a change', () async {
      final src = _Src('legacy', _row(null, {'v': 'old'}));
      fake.hook = (i, _) async {
        if (i == 0) src.row = _row(7, {'v': 'new'});
      };

      final out = await lane.decode(src, _row(null, {'v': 'old'}));

      expect((out!.value as Map)['v'], 'new');
    });

    test('unchanged and still without a revision: accepted, not cached',
        () async {
      final src = _Src('legacy', _row(null, {'v': 'same'}));

      final out = await lane.decode(src, _row(null, {'v': 'same'}));

      expect((out!.value as Map)['v'], 'same');
      expect(lane.debugEntries, 0);
    });

    test('sleepWindows over a legacy row replaced mid-decode', () async {
      await p25SeedWindows(db);
      final fake2 = _JsonLane();
      JsonPayloadLane.debugUseShared(JsonPayloadLane(lane: fake2));
      final day = p25WindowDays[15];
      // Written before row_rev existed: no revision row.
      await db.delete('row_rev',
          where: "kind = 'day_result' AND k1 = ?", whereArgs: [day]);
      fake2.hook = (i, _) async {
        if (i != 0) return;
        // An UPDATE does not fire the revision trigger: still no revision.
        await db.update(
          'day_result',
          {'window_json': jsonEncode({'onset_ms': 1000000, 'offset_ms': 2000000})},
          where: 'day_id = ?',
          whereArgs: [day],
        );
      };

      final rows = await LocalRepositoryImpl(getProfileMap: () => p22Profile)
          .sleepWindows(days: 14);

      final r = rows.firstWhere((r) => r['date'] == day);
      expect(r['onset_ts'], 1000);
      expect(r['wake_ts'], 2000);
    });
  });

  group('4: LastResultCache.put is fenced against the generation', () {
    test('a wipe while the worker encodes: the table stays empty and a later '
        'read finds nothing', () async {
      final fake = _JsonLane();
      JsonPayloadLane.debugUseShared(JsonPayloadLane(lane: fake));
      final arrived = Completer<void>();
      final release = Completer<void>();
      fake.hook = (i, input) async {
        if (!input.encode) return;
        arrived.complete();
        await release.future;
      };
      final cache = LastResultCache();

      cache.put<Map<String, dynamic>>('beats|2025-06-01', {'nn': [1, 2, 3]}, sig: 's');
      await arrived.future;
      await LocalDb.wipeAll();
      release.complete();
      await cache.flush();

      expect(await LocalDb.lastResult('beats|2025-06-01'), isNull);
      final later = LastResultCache();
      expect(await later.read<Map<String, dynamic>>('beats|2025-06-01'), isNull);
    });

    test('the legitimate first open is still allowed: a put on a CLOSED store '
        'reaches the table', () async {
      final cache = LastResultCache();
      await LocalDb.close();

      cache.put<Map<String, dynamic>>('beats|2025-06-02', {'nn': [4, 5]});
      await cache.flush();

      expect((await LocalDb.lastResult('beats|2025-06-02'))?.payload, contains('"nn"'));
    });
  });

  group('3: the Android export revalidates its retained priority bundle', () {
    final days = [for (var i = 1; i <= 8; i++) '2025-03-${i.toString().padLeft(2, '0')}'];
    late List<String> sleepCalls;
    late List<String> healthCalls;

    void mockChannels() {
      SharedPreferences.setMockInitialValues({});
      sleepCalls = [];
      healthCalls = [];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      void on(String name, Future<Object?> Function(MethodCall c) handler) {
        messenger.setMockMethodCallHandler(MethodChannel(name), handler);
        addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(name), null));
      }

      on('openstrap/health_connect_sleep', (c) async {
        sleepCalls.add('${c.arguments}');
        return true;
      });
      on('openstrap/health_connect_heart_rate', (c) async => true);
      on('flutter_health', (c) async {
        healthCalls.add('${c.method} ${c.arguments}');
        return true;
      });
    }

    /// Eight finalized days, all with sleep; the NEWEST is the priority night
    /// and the bulk pass (oldest first) reaches it last.
    Future<P22Lane> seed() async {
      final lane = P22Lane();
      p22UseStore(p22Store(lane));
      for (var i = 0; i < days.length; i++) {
        await p22Seed(db, days[i], p22DayBundle(days[i], i: i), finalized: true, computedAt: 1000 + i);
      }
      return lane;
    }

    /// Runs [onFirstBulk] at the first full decode after the priority night's.
    void atFirstBulk(P22Lane lane, Future<void> Function() onFirstBulk) {
      var fulls = 0;
      lane.hook = (index, chunk) async {
        if (!chunk.projections.contains('full')) return;
        if (++fulls == 2) await onFirstBulk();
      };
    }

    test('control: nothing changes, the priority night is written once',
        () async {
      mockChannels();
      await seed();

      await HealthExporter(platform: const _Android()).exportAll();

      expect(sleepCalls, hasLength(days.length), reason: 'one sleep write per night');
    });

    test('a re-derive of the priority night during the bulk pass: its new '
        'scalars are exported and its sleep session is written again', () async {
      mockChannels();
      final lane = await seed();
      final newest = days.last;
      atFirstBulk(lane, () async {
        final b = p22DayBundle(newest, i: 3, marker: 'rederived');
        final win = (((b['sleep'] as Map)['window'] as Map)['value'] as Map);
        win['onset_ms'] = 1577926800000.0; // an hour later than the fixture's
        await p22Seed(db, newest, b, finalized: true, computedAt: 9000);
      });

      await HealthExporter(platform: const _Android()).exportAll();

      expect(sleepCalls, hasLength(days.length + 1),
          reason: 'the priority night is written before AND after the re-derive');
      expect(sleepCalls.where((c) => c.contains('startTime: 1577926800000')), isNotEmpty,
          reason: 'the re-derived night\'s new sleep window was exported');
    });

    test('a wipe during the bulk pass aborts the export: nothing more is '
        'written and no cursor lands in the emptied store', () async {
      mockChannels();
      final lane = await seed();
      var atWipe = -1;
      atFirstBulk(lane, () async {
        await LocalDb.wipeAll();
        atWipe = sleepCalls.length + healthCalls.length;
      });

      final done = await HealthExporter(platform: const _Android()).exportAll();

      expect(atWipe, greaterThan(-1), reason: 'guard: the wipe ran');
      expect(done, 0);
      expect(sleepCalls.length + healthCalls.length, atWipe,
          reason: 'no export write after the wipe');
      expect(await LocalDb.getCursor('health_export_through') ?? '', isEmpty);
    });
  });
}
