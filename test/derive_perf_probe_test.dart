// Timing probe, not a regression test: restores the owner's 5 Oct export,
// then runs what the app runs after an import (finalizeImport, one heavy
// pass, the baseline rescan) on the real DerivationEngine and prints the
// [perf] log lines plus wall ms per day.
//
//   DERIVE_PERF_PROBE=1 flutter test test/derive_perf_probe_test.dart
//   DERIVE_UNION=0 ...   loads each day's windows one by one (no cross-day union)
//
// IMPORT_PERF_SRC overrides the export path.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _defaultSrc = '/home/mini/Documents/repos/edge.research/data/'
    'openstrap_export_1791234499279.db';

class _CapturePerf extends DerivePerf {
  _CapturePerf(void Function(String) note)
      : _note = note,
        super(nowMs: () => DateTime.now().millisecondsSinceEpoch);
  final void Function(String) _note;
  @override
  void addPhase(String day, DerivePhase phase, int ms) {
    _note('PHASE $day ${phase.name} $ms ms');
    super.addPhase(day, phase, ms);
  }
}

void main() {
  final srcPath = Platform.environment['IMPORT_PERF_SRC'] ?? _defaultSrc;

  test('derive pass after restore', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('openstrap_dperf_');
    LocalDb.dbName = 'openstrap_derive_perf_probe.db';
    final dbDir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    final out = <String>[];
    final clock = Stopwatch()..start();
    void note(String m) {
      final l = '[probe +${clock.elapsedMilliseconds}ms] $m';
      out.add(l);
    }

    try {
      final copy = p.join(tmp.path, 'export.db');
      await File(srcPath).copy(copy);
      await LocalDb.instance;
      final t0 = clock.elapsedMilliseconds;
      await LocalDb.importFromDbFile(copy);
      note('import ${clock.elapsedMilliseconds - t0} ms');

      const profile = Profile(
          ageYears: 35,
          weightKg: 75,
          heightCm: 178,
          sex: 'male',
          restingHrManual: 54);
      final engine = DerivationEngine(
          log: (m) => note('LOG $m'), perf: _CapturePerf(note));
      engine.debugDayHook = (d) async => note('DAY START $d');
      engine.debugDisableSubstrateUnionLoad =
          Platform.environment['DERIVE_UNION'] == '0';

      var t = clock.elapsedMilliseconds;
      await engine.finalizeImport(profile);
      note('finalizeImport ${clock.elapsedMilliseconds - t} ms');

      var last = clock.elapsedMilliseconds;
      t = last;
      final n = await engine.run(
        profile,
        heavy: true,
        onScopeDays: (d) => note('scope days=$d'),
        onDayDone: (day, i, total) {
          final now = clock.elapsedMilliseconds;
          note('DAY $day ($i/$total) wall ${now - last} ms');
          last = now;
        },
        onCrossDay: (a) => note('crossDay active=$a'),
      );
      note('heavy run computed=$n total ${clock.elapsedMilliseconds - t} ms');

      last = t = clock.elapsedMilliseconds;
      final r = await engine.rescanRecent(
        profile,
        onScopeDays: (d) => note('rescan scope days=$d'),
        onDayDone: (day, i, total) {
          final now = clock.elapsedMilliseconds;
          note('RESCAN DAY $day ($i/$total) wall ${now - last} ms');
          last = now;
        },
      );
      note('rescanRecent n=$r total ${clock.elapsedMilliseconds - t} ms');
    } finally {
      // ignore: avoid_print
      print(out.join('\n'));
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
      await tmp.delete(recursive: true);
    }
  },
      skip: Platform.environment['DERIVE_PERF_PROBE'] != '1',
      timeout: const Timeout(Duration(minutes: 40)));
}
