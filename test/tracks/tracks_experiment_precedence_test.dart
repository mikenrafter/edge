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
    expect(((persisted['displayed_effects'] as List).single as Map)['effect'], closeTo(8, 1e-9));
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

  Future<Map> persistedState() async => jsonDecode(
    (await db.query('track_learning', where: 'track_id = ?', whereArgs: ['custom'])).single['state_json'] as String,
  ) as Map;

  // why: review R3-1 (blocker). The latest experiment ROW was taken before
  // checking completion, so a newer running, future or stopped experiment
  // erased the previous completed result without any release by the wearer.
  // The latest ELIGIBLE (completed) result is preferred.
  // proves: CLAIM(experiment-precedence)
  test('a newer running, future or stopped experiment does not remove the completed result', () async {
    await runExperiment('2026-09-01', 8, 17); // completed
    final asOf = DateTime(2026, 9, 20, 12);
    // Newer, stopped: runs 09-16.. and is stopped on 09-18.
    final stopped = await store.startExperiment(trackId: 'custom', startDate: '2026-09-16', weeks: 2, seed: 3);
    await withClock(Clock.fixed(DateTime(2026, 9, 18, 9)), () => store.stopExperiment(stopped['id'] as String));
    // Newer, running at asOf, and newer still, in the future.
    await store.startExperiment(trackId: 'custom', startDate: '2026-09-19', weeks: 2, seed: 5);
    await store.startExperiment(trackId: 'custom', startDate: '2026-12-01', weeks: 2, seed: 9);
    final effect = hrEffect(await store.refreshLearning(asOf: asOf));
    // R4-1: while the newer experiment runs, the older completed result is still
    // the displayed effect, exactly; only the observational list abstains (the
    // kinetic-learning pause is kept).
    expect(effect['reason'], 'from_experiment');
    expect(effect['effect'], closeTo(8, 1e-9));
    final during = await persistedState();
    expect(((during['effects'] as List).single as Map)['reason'], 'experiment_learning');
    expect(((during['effects'] as List).single as Map)['effect'], isNull);
    // After the running one ends unreportable (no adherence), the older completed
    // result is still the one shown.
    final later = hrEffect(await store.refreshLearning(asOf: DateTime(2026, 10, 20, 12)));
    expect(later['reason'], 'from_experiment');
    expect(later['effect'], closeTo(8, 1e-9));
    expect(asOf.isBefore(DateTime(2026, 10, 20)), isTrue);
  });

  test('a newer completed experiment that cannot report leaves the older one in place', () async {
    await runExperiment('2026-09-01', 8, 17);
    // Completed by the calendar but no followed days: insufficient adherence.
    await store.startExperiment(trackId: 'custom', startDate: '2026-10-01', weeks: 2, seed: 5);
    final effect = hrEffect(await store.refreshLearning(asOf: DateTime(2026, 10, 25, 12)));
    expect(effect['reason'], 'from_experiment');
    expect(effect['effect'], closeTo(8, 1e-9));
  });

  // why: review R3-5. Displaying an experiment effect must not overwrite the
  // observational estimates that custom detection reads from `effects`
  // (TrackDetectors.stable needs reason `estimated` plus an adjusted p). They
  // live in `effects`; the shown ones in `displayed_effects`.
  // proves: CLAIM(experiment-precedence)
  test('observational effects stay in the state; the shown ones are kept apart', () async {
    await runExperiment('2026-09-01', 8, 17);
    final asOf = DateTime(2026, 9, 20, 12);
    final shown = hrEffect(await store.refreshLearning(asOf: asOf));
    expect(shown['reason'], 'from_experiment');
    final state = await persistedState();
    final observational = (state['effects'] as List).cast<Map>().single;
    expect(observational['reason'], isNot('from_experiment'));
    expect(observational['experiment_id'], isNull);
    expect(((state['displayed_effects'] as List).single as Map)['reason'], 'from_experiment');
    // Releasing shows exactly what was kept observationally.
    await store.releaseExperimentPrecedence('custom');
    final after = hrEffect(await store.refreshLearning(asOf: asOf));
    expect(after['reason'], observational['reason']);
    expect(after['effect'], observational['effect']);
  });
}
