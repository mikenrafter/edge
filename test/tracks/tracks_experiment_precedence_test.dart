import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';
import 'ui_support.dart';

// Review T18 (orchestrator decision): a completed experiment's effect for a
// track x system is PREFERRED over the observational estimate, labelled
// "from_experiment", until a newer experiment completes or the wearer releases
// it. Expected effects are hand-derived from the fixture: do nights are
// 68 + noise, skip nights 60 + noise with the same noise sequence, so the
// effect is 8 bpm (the second experiment uses 70 vs 60: 10 bpm).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_experiment_precedence.db');
    db = await LocalDb.instance;
    store = TracksStore(db);
    await store.saveDefinition(
      const TrackDefinition(id: 'custom', name: 'Walk', icon: 'track', kind: 'activity', systems: ['hr']),
    );
    await db.insert('track_learning', {
      'track_id': 'custom',
      'started_ms': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'last_step_date': '2026-01-01',
      'state_json': jsonEncode({'effects': []}),
    });
  });
  tearDown(() => env.dispose());

  Future<Map> runExperiment(String from, int gap, int seed) =>
      runFollowedExperiment(db, store, from: from, gap: gap, seed: seed);

  Map hrEffect(Map<String, Map<String, Object?>> summary) =>
      (summary['custom']!['effects'] as List).cast<Map>().singleWhere((e) => e['system'] == 'hr');

  // proves: CLAIM(experiment-precedence)
  test('after completion the learned effect equals the experiment effect', () async {
    await runExperiment('2026-09-01', 8, 17);
    // While it runs: abstention. After the last night: its effect, labelled.
    final during = hrEffect(await store.refreshLearning(asOf: DateTime(2026, 9, 5, 12)));
    expect(during['reason'], 'experiment_learning');
    expect(during['effect'], isNull);
    final summary = await store.refreshLearning(asOf: DateTime(2026, 9, 20, 12));
    final effect = hrEffect(summary);
    expect(effect['reason'], 'from_experiment');
    expect(effect['effect'], closeTo(8, 1e-9));
    expect(effect['experiment_id'], isNotNull);
    expect(summary['custom']!['reason'], 'from_experiment');
    final persisted = jsonDecode((await db.query('track_learning', where: 'track_id = ?', whereArgs: ['custom'])).single['state_json'] as String) as Map;
    expect(((persisted['effects'] as List).single as Map)['effect'], closeTo(8, 1e-9));
  });

  test('a newer completed experiment replaces the older result', () async {
    await runExperiment('2026-09-01', 8, 17);
    await runExperiment('2026-10-01', 10, 5);
    final effect = hrEffect(await store.refreshLearning(asOf: DateTime(2026, 10, 20, 12)));
    expect(effect['reason'], 'from_experiment');
    expect(effect['effect'], closeTo(10, 1e-9));
  });

  test('releasing it returns to the observational estimate until a newer experiment', () async {
    await runExperiment('2026-09-01', 8, 17);
    final asOf = DateTime(2026, 9, 20, 12);
    await store.refreshLearning(asOf: asOf);
    await store.releaseExperimentPrecedence('custom');
    final released = hrEffect(await store.refreshLearning(asOf: asOf));
    expect(released['reason'], isNot('from_experiment'));
    expect(released['effect'], isNot(closeTo(8, 1e-9)));
    // Stays released on later passes.
    expect(hrEffect(await store.refreshLearning(asOf: DateTime(2026, 9, 25, 12)))['reason'], isNot('from_experiment'));
    // A newer experiment is a new result: it is preferred again.
    await runExperiment('2026-10-01', 10, 5);
    final again = hrEffect(await store.refreshLearning(asOf: DateTime(2026, 10, 20, 12)));
    expect(again['reason'], 'from_experiment');
    expect(again['effect'], closeTo(10, 1e-9));
  });

  test('a stopped experiment and a track without one never override', () async {
    final experiment = await runExperiment('2026-09-01', 8, 17);
    await withClock(Clock.fixed(DateTime(2026, 9, 10, 9)), () => store.stopExperiment(experiment['id'] as String));
    expect(hrEffect(await store.refreshLearning(asOf: DateTime(2026, 9, 20, 12)))['reason'], isNot('from_experiment'));
  });

  test('releasing with nothing from an experiment is a no-op; unknown track refuses', () async {
    await store.releaseExperimentPrecedence('custom');
    await expectLater(store.releaseExperimentPrecedence('nope'), throwsArgumentError);
  });
}
