// One place decides that a past, final day's strain abstention is final, and
// no other path turns a `need_baseline:` strain note into "Need N more
// nights" (AGENTS 4.7: a capability wired into one call path but not all).
//
// Readers of a strain note: getDayStrain (the day screen, Home's day view),
// including its fallback to the latest settled bundle when asked for today;
// getToday serves only TODAY's own day, which can still gain nights. Trends,
// the coach views and the widget read numbers, or getToday's Metric.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _note = 'need_baseline:have=1,need=3';

Future<void> _put(String day, {required bool finalized, int? version}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: version ?? kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day, // a derived bundle names its own day
        'absent_notes': {'strain': _note},
        'scalars': {'steps': 100.0},
      }),
      windowJson: '{}',
      finalized: finalized,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_strain_final_note_readers_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => const {'age': 30});

  void expectFinal(Map<String, dynamic> s) {
    final top = s['note'] as String?;
    expect(top, isNotNull);
    expect(needMoreNightsFromNote(top), isNull, reason: 'promises nights: $top');
    final strain = Metric.parse((s['absent'] as Map)['strain']);
    expect(strain.needMoreNights, isNull);
    expect(whyFromNote(top), isNotNull);
  }

  test('a settled (declined) past day, not finalized, gives the final reason',
      () async {
    await _put('2020-05-01', finalized: false);
    await LocalDb.putSettledDay('2020-05-01', kAlgoVersion, own: 'x', prev: null);
    expectFinal(await repo.getDayStrain('2020-05-01'));
  });

  test('a day finalized at an older version is not final for this one',
      () async {
    await _put('2020-05-02', finalized: true, version: kAlgoVersion - 1);
    final s = await repo.getDayStrain('2020-05-02');
    expect(s['note'], _note, reason: 'it will be re-derived under this version');
  });

  test('asked for today, the latest settled bundle served is judged by ITS '
      'day, not by the day asked', () async {
    final today = todayLabel();
    final yesterday = dayLabelBefore(today, 1)!;
    await _put(yesterday, finalized: true);
    final s = await repo.getDayStrain(today);
    if (s.isEmpty) return; // no fallback served: nothing to judge
    expectFinal(s);
  });

  test('no path outside the shared seam turns a need_baseline note into '
      '"Need N more nights"', () {
    const allowed = {
      'lib/models/metric.dart', // the parser itself
      'lib/data/local_repository_impl.dart', // the one seam
      'lib/ui2/profile/gallery.dart', // demo fixtures
    };
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.startsWith('lib/compute/') || f.path.startsWith('lib/l10n/')) {
        continue; // producers of the note, and generated strings
      }
      if (allowed.contains(f.path)) continue;
      // Code, not comments: a string literal naming the note.
      final code = f
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      if (RegExp('[\'"]need_baseline').hasMatch(code)) offenders.add(f.path);
    }
    expect(offenders, isEmpty,
        reason: 'parse notes through models/metric.dart; decide finality in '
            'LocalRepositoryImpl._finalAbsenceNote only');
  });
}
