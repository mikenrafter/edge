// P2.5 PARITY ANCHOR (design 02 step 2, section 2 B6, B7, B9, B11, B12 and the
// P2.3 carry-over (a) and (b); section 5 P2.5).
//
// Written to PASS on the code as it stood before P2.5 (HEAD 82f4fa24) and to
// keep passing after it: every reader P2.5 moves behind the worker lane must
// return exactly what it returned. Each scenario seeds a fresh database and
// records the reader's output as JSON text; test/step2/golden/
// p25_reader_outputs.json holds what the pre-P2.5 code produced.
//
//   diagnostics   LocalDb.recentDayDiagnostics(1, 3, 5, 10)            (B6)
//   windows       LocalRepositoryImpl.sleepWindows() default, 14, 3    (a)
//   kcal          LocalRepositoryImpl.getDayCalorieCurve, five days    (B9)
//   last_result   LastResultCache.read, six keys, three types each     (B7)
//   put_text      the stored text a LastResultCache.put leaves          (B7)
//   wake_today    getToday() and getDayStrain(today) when today has only a
//                 wake_day_features row (the interim estimate)          (b)
//   health        every platform call HealthExporter.exportAll makes over
//                 six days (finalized, open, skipped, undecodable, no sleep)
//                                                                       (B12)
//
// Not here: the recovery note (B11) and the two screen loaders (B10). Their
// outputs are a notification body and a few typed fields; they are asserted
// literally in p25_reader_parity_test.dart.
//
// DATE-INDEPENDENT. Every reader above except `wake_today` is seeded with fixed
// day labels and fixed timestamps, so its output cannot move with the date.
// `wake_today` depends on today by nature; it is seeded with `p23Day(n)` labels
// and recorded with each label replaced by `<D0>`, `<D1>`, ... in BOTH
// directions (p25Tokens), and `LocalDb.nowMs` is frozen. The test records the
// local date it started under and skips if it rolled over mid-run. No expected
// value is computed from the clock.
//
// Recording: `P25_WRITE_GOLDEN=1 TZ=UTC flutter test <this file>` rewrites the
// golden from whatever code is checked out. Only do that from a commit whose
// readers are known good (this one was recorded at HEAD 82f4fa24). Under a zone
// other than UTC the day windows differ and the test skips.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/p25_support.dart';

const _name = 'p25_golden.db';
const _goldenPath = 'test/step2/golden/p25_reader_outputs.json';

Future<String> _run(Future<Object?> Function() read) async {
  try {
    // The served algo version is a build constant, not a reader's output.
    return p25Text(await read()).replaceAll('"algo_version":$p21Version', '"algo_version":<V>');
  } catch (e) {
    return 'ERROR ${e.runtimeType}';
  }
}

Future<String> _cacheRead<T>(String key) async {
  final r = await LastResultCache().read<T>(key);
  if (r == null) return 'null';
  return p25Text({'v': r.value, 'at': r.cachedAt.millisecondsSinceEpoch, 'sig': r.sig});
}

/// Every channel call the exporter made, in order, arguments in a canonical
/// order. The per-day retry cursor holds `DateTime.now()` and is not read.
Future<Map<String, String>> _healthRun(Database db) async {
  SharedPreferences.setMockInitialValues({});
  final calls = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter_health'), (c) async {
    final args = c.arguments;
    final text = args is Map
        ? jsonEncode({for (final k in (args.keys.toList()..sort())) '$k': args[k]})
        : '$args';
    calls.add('${c.method} $text');
    return true;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter_health'), null));

  const days = ['2025-03-01', '2025-03-02', '2025-03-03', '2025-03-04', '2025-03-05', '2025-03-06'];
  await p22Seed(db, days[0], p22DayBundle(days[0], i: 1), finalized: true, computedAt: 1001);
  await p22Seed(db, days[1], p22DayBundle(days[1], i: 2), computedAt: 1002);
  await p25Row(db, days[2],
      payload: jsonEncode({'skipped': true, 'reason': 'x'}), skipped: 1, computedAt: 1003);
  await p25Row(db, days[3], payload: '{bad', computedAt: 1004, finalized: 1);
  await p22Seed(db, days[4], p22DayBundle(days[4], i: 5, sleep: false), computedAt: 1005);
  await p22Seed(db, days[5], p22DayBundle(days[5], i: 6), finalized: true, computedAt: 1006);

  final done = await HealthExporter().exportAll();
  return {
    'exported': '$done',
    'through': (await LocalDb.getCursor('health_export_through')) ?? 'null',
    'calls': calls.join('\n'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  setUp(() => BundleStore.debugResetShared());
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  test('every moved reader returns exactly what the pre-P2.5 code returned',
      () async {
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      markTestSkipped('golden is recorded under TZ=UTC');
      return;
    }
    final started = p23Day(0);
    final got = <String, String>{};
    LocalDb.nowMs = P21Clock(1700000000000).call;

    // -- diagnostics (B6) ----------------------------------------------------
    var db = await p21Fresh(_name);
    await p25SeedDiagnostics(db);
    for (final n in const [1, 3, 5, 10]) {
      got['diagnostics($n)'] = await _run(() => LocalDb.recentDayDiagnostics(n));
    }

    // -- windows (a) ---------------------------------------------------------
    db = await p21Fresh(_name);
    await p25SeedWindows(db);
    final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);
    got['windows()'] = await _run(() => repo.sleepWindows());
    got['windows(14)'] = await _run(() => repo.sleepWindows(days: 14));
    got['windows(3)'] = await _run(() => repo.sleepWindows(days: 3));

    // -- kcal (B9) -----------------------------------------------------------
    db = await p21Fresh(_name);
    await p25SeedKcal();
    for (final d in const [p25KcalFull, p25KcalSparse, p25KcalNoMinutes, p25KcalList, p25KcalMissing]) {
      got['kcal($d)'] = await _run(() => LocalRepositoryImpl(getProfileMap: () => p22Profile).getDayCalorieCurve(d));
    }

    // -- last_result (B7) ----------------------------------------------------
    db = await p21Fresh(_name);
    await p25SeedLastResults();
    for (final key in [...p25LastResultRows().keys, 'absent']) {
      got['last_result(dynamic,$key)'] = await _cacheRead<dynamic>(key);
      got['last_result(map,$key)'] = await _cacheRead<Map<String, dynamic>>(key);
      got['last_result(list,$key)'] = await _cacheRead<List<dynamic>>(key);
    }

    // -- put (B7): the text left in the table -----------------------------------
    db = await p21Fresh(_name);
    final cache = LastResultCache(now: () => DateTime.fromMillisecondsSinceEpoch(9100));
    cache.put<Map<String, dynamic>>('put|big', p25BigArtifact(), sig: 's1');
    cache.put<Map<String, dynamic>>('put|small', {'b': 1, 'a': [1.0, 2, null], 'c': {'d': 'é'}});
    cache.put<Object?>('put|list', [1, 2, 3]); // not a Map: memory only
    cache.put<Object?>('put|unencodable', {'when': DateTime(2020)}); // jsonEncode throws: memory only
    await cache.flush();
    for (final key in const ['put|big', 'put|small', 'put|list', 'put|unencodable']) {
      final row = await LocalDb.lastResult(key);
      got['put_text($key)'] = row == null
          ? 'null'
          : p25Text({'at': row.computedAt, 'sig': row.sig, 'text': row.payload});
    }

    // -- wake-only today (b) -----------------------------------------------------
    db = await p21Fresh(_name);
    final today = p23Day(0);
    await p22Seed(db, p23Day(1), p22DayBundle(p23Day(1), i: 2), computedAt: 1002);
    await p22Seed(db, p23Day(2), p22DayBundle(p23Day(2), i: 3), computedAt: 1003);
    await p25Wake(db, today, {
      'strain': 7.5,
      'wear_min': 612.0,
      'active_min': 95.0,
      'calories': 480.4,
      'calories_total': 2310.6,
      'steps': 5123.4,
      'absent_notes': {'spo2': 'no_input'},
      'activity': {'level': 'moderate', 'minutes': [1, 2, 3]},
    });
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'algo_version': p21Version,
        'built_for_day': today,
        'sleep_coach': {'need': {'value': {'need_sec': 28800}}},
        'load': {'acwr': 1.1},
      }),
    );
    final wakeRepo = LocalRepositoryImpl(getProfileMap: () => p22Profile);
    got['wake_today.getToday'] = p25Tokens(await _run(() => wakeRepo.getToday()));
    got['wake_today.getDayStrain'] = p25Tokens(await _run(() => wakeRepo.getDayStrain(today)));
    got['wake_today.getToday#2'] = p25Tokens(await _run(() => wakeRepo.getToday()));

    // -- health export (B12) -------------------------------------------------------
    db = await p21Fresh(_name);
    final health = await _healthRun(db);
    for (final e in health.entries) {
      got['health.${e.key}'] = e.value;
    }

    if (p23Day(0) != started) {
      markTestSkipped('the local date rolled over during the run');
      return;
    }

    if (Platform.environment['P25_WRITE_GOLDEN'] == '1') {
      File(_goldenPath).writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(got)}\n',
      );
      return;
    }

    final want = (jsonDecode(File(_goldenPath).readAsStringSync()) as Map)
        .cast<String, String>();
    expect(got.keys.toList(), want.keys.toList(), reason: 'same readers, same order');
    for (final k in want.keys) {
      expect(got[k], want[k], reason: 'reader output changed: $k');
    }

    // The anchor must hold real answers, not a table of nulls and errors.
    expect(want.values.where((v) => v.startsWith('ERROR')), isEmpty);
    expect(want['diagnostics(10)']!.length, greaterThan(500));
    expect(want['windows(14)']!.length, greaterThan(500));
    expect(want['kcal($p25KcalFull)']!.length, greaterThan(50000));
    expect(want['last_result(map,beats|2025-06-01)']!.length, greaterThan(50000));
    expect(want['put_text(put|big)']!.length, greaterThan(50000));
    expect(want['wake_today.getToday']!, contains('5123'),
        reason: 'the wake estimate reached Home');
    expect(want['health.calls']!.split('\n').length, greaterThan(20));
  });
}
