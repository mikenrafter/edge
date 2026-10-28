import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import 'package:openstrap_edge/ui2/screens/track_experiment.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
import '../backup/backup_support.dart';
import '../support/bundled_fonts.dart';
import 'ui_support.dart';

Future<void> _expand(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  late BackupEnv env;
  late ObservedTracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_ui_t1.db');
    store = ObservedTracksStore(await LocalDb.instance);
  });
  tearDown(() async => env.dispose());

  testWidgets(
    'preset edits persist unknown values, locks, roles, bounds and explicit history',
    (t) async {
      final caffeine = (await t.runAsync(
        () => store.definitions(),
      ))!.firstWhere((d) => d.id == 'caffeine');
      await mountTracks(
        t,
        TrackEditor(store: store, initial: caffeine),
        height: 2400,
      );
      await settleTracks(t, store);
      await t.enterText(find.byKey(const ValueKey('track-name')), 'My tea');
      await t.enterText(
        find.byKey(const ValueKey('kinetics-half_life_hours')),
        '6.5',
      );
      await t.tap(find.byKey(const ValueKey('kinetics-half_life_hours-lock')));
      await t.enterText(
        find.byKey(const ValueKey('kinetics-tolerance_days')),
        '',
      );
      await _expand(t, 'Roles');
      await t.tap(find.widgetWithText(CheckboxListTile, 'Detectable'));
      await _expand(t, 'Affected systems');
      await t.enterText(
        find.byKey(const ValueKey('track-custom-system')),
        'Future sensor',
      );
      await t.tap(find.byTooltip('Add a system'));
      await _expand(t, 'Sub-activities');
      await _expand(t, 'Tea');
      await t.ensureVisible(find.byKey(const ValueKey('sub-tea-onset_hours')));
      await t.enterText(
        find.byKey(const ValueKey('sub-tea-onset_hours')),
        '1.25',
      );
      await t.tap(find.byKey(const ValueKey('sub-tea-onset_hours-lock')));
      await _expand(t, 'Daily detection bounds');
      await t.enterText(find.byKey(const ValueKey('track-detection-min')), '1');
      await t.enterText(find.byKey(const ValueKey('track-detection-max')), '3');
      await _expand(t, 'Setup history');
      await t.tap(find.byKey(const ValueKey('track-no-clean')));
      await t.tap(find.byKey(const ValueKey('track-add-history')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Not done'));
      await t.pumpAndSettle();
      await t.tap(find.text('Not done'));
      await t.tap(find.byKey(const ValueKey('track-save')));
      await settleTracks(t, store);
      final saved = (await t.runAsync(
        () => store.definitions(),
      ))!.firstWhere((d) => d.id == 'caffeine');
      expect(saved.name, 'My tea');
      expect(saved.kinetics.fields['half_life_hours']!.value, 6.5);
      expect(saved.kinetics.fields['half_life_hours']!.locked, true);
      expect(saved.kinetics.fields['tolerance_days']!.value, isNull);
      final tea = saved.subActivities.firstWhere((s) => s.id == 'tea');
      expect(tea.kinetics.fields['onset_hours']!.value, 1.25);
      expect(tea.kinetics.fields['onset_hours']!.locked, true);
      expect(
        saved.kinetics.fields['onset_hours']!.value,
        isNull,
        reason: 'A sub-activity override must not overwrite the track default',
      );
      expect(saved.roles.toSet(), {'own_sleep', 'detectable'});
      expect(saved.systems.toSet(), {'sleep', 'Future sensor'});
      expect((saved.detectionMin, saved.detectionMax), (1, 3));
      expect(saved.noUnadjustedData, true);
      final history = (await t.runAsync(() => store.history('caffeine')))!;
      expect(history, hasLength(1));
      expect(history.single.done, false);
      expect(history.single.startDate, history.single.endDate);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('invalid bounds stay editable and do not partially save a name', (
    t,
  ) async {
    final caffeine = (await t.runAsync(
      () => store.definitions(),
    ))!.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(
      t,
      TrackEditor(store: store, initial: caffeine),
      height: 2400,
    );
    await settleTracks(t, store);
    await t.enterText(
      find.byKey(const ValueKey('track-name')),
      'Should not save',
    );
    await _expand(t, 'Daily detection bounds');
    await t.enterText(find.byKey(const ValueKey('track-detection-min')), '5');
    await t.enterText(find.byKey(const ValueKey('track-detection-max')), '2');
    await t.tap(find.byKey(const ValueKey('track-save')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-form-error')), findsOneWidget);
    expect(find.byType(TrackEditor), findsOneWidget);
    final saved = (await t.runAsync(
      () => store.definitions(),
    ))!.firstWhere((d) => d.id == 'caffeine');
    expect(saved.name, 'Caffeine');
    expect((saved.detectionMin, saved.detectionMax), (0, 10));
  });

  testWidgets(
    'timed log preserves an unknown amount and selected sub-activity',
    (t) async {
      final caffeine = (await t.runAsync(
        () => store.definitions(),
      ))!.firstWhere((d) => d.id == 'caffeine');
      await mountTracks(
        t,
        TrackLogScreen(store: store, track: caffeine, date: '2026-10-20'),
      );
      await settleTracks(t, store);
      await t.tap(find.byKey(const ValueKey('track-log-sub-caffeine')));
      await t.pumpAndSettle();
      await t.tap(find.text('Tea').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('track-log-save')));
      await settleTracks(t, store);
      final rows = (await t.runAsync(() => store.events(trackId: 'caffeine')))!;
      expect(rows, hasLength(1));
      expect(rows.single.date, '2026-10-20');
      expect(rows.single.amount, isNull);
      expect(rows.single.subActivityId, 'tea');
      final at = DateTime.fromMillisecondsSinceEpoch(
        rows.single.atMs!,
        isUtc: true,
      );
      expect((at.year, at.month, at.day), (2026, 10, 20));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'create flow persists a custom track with default detection bounds',
    (t) async {
      await mountTracks(t, TracksScreen(store: store));
      await settleTracks(t, store);
      await t.tap(find.text('Create track'));
      await settleTracks(t, store);
      await t.enterText(find.byKey(const ValueKey('track-name')), 'Reading');
      await t.enterText(find.byKey(const ValueKey('track-unit')), 'minutes');
      await t.tap(find.byKey(const ValueKey('track-save')));
      await settleTracks(t, store);
      final custom = (await t.runAsync(
        () => store.definitions(),
      ))!.where((d) => d.name == 'Reading').single;
      expect((custom.kind, custom.unit), ('activity', 'minutes'));
      expect((custom.detectionMin, custom.detectionMax), (0, 10));
      expect(custom.kinetics.fields['half_life_hours']!.value, isNull);
      expect(find.byKey(ValueKey('track-card-${custom.id}')), findsOneWidget);
    },
  );

  // why: owner decision 2026-10-27 on review T1. A prescribed track still shows
  // "Start an experiment", but the setup screen only explains and has no Begin.
  // proves: CLAIM(never-ask-skip-prescribed)
  testWidgets('medication setup explains and offers no Begin; a custom track begins', (
    t,
  ) async {
    await t.runAsync(() async {
      await MedDb.putDef(
        await LocalDb.instance,
        const MedDef(key: 'metformin', label: 'Metformin', doseValue: 500, doseUnit: 'mg'),
      );
    });
    final defs = (await t.runAsync(() => store.definitions()))!;
    final med = defs.firstWhere((d) => d.id == 'med:metformin');
    await mountTracks(t, TrackDetailScreen(store: store, track: med));
    await settleTracks(t, store);
    expect(find.text('Start an experiment'), findsOneWidget);
    await t.ensureVisible(find.text('Start an experiment'));
    await t.tap(find.text('Start an experiment'));
    await settleTracks(t, store);
    expect(find.byKey(const ValueKey('experiment-prescribed')), findsOneWidget);
    expect(find.textContaining('never randomized'), findsOneWidget);
    expect(find.text('Begin experiment'), findsNothing);
    expect(find.text('2 weeks'), findsNothing);
  });

  testWidgets('a custom track setup still offers Begin', (t) async {
    final caffeine = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'sauna');
    await mountTracks(t, TrackDetailScreen(store: store, track: caffeine));
    await settleTracks(t, store);
    await t.ensureVisible(find.text('Start an experiment'));
    await t.tap(find.text('Start an experiment'));
    await settleTracks(t, store);
    expect(find.text('Begin experiment'), findsOneWidget);
    expect(find.byKey(const ValueKey('experiment-prescribed')), findsNothing);
  });

  // why: owner decision 2026-10-27. Marking a custom track prescribed from the
  // editor persists the flag; a medication shows it checked and locked.
  testWidgets('editor Prescribed checkbox persists', (t) async {
    final caffeine = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'sauna');
    await mountTracks(t, TrackEditor(store: store, initial: caffeine), height: 2400);
    await settleTracks(t, store);
    final box = find.byKey(const ValueKey('track-prescribed'));
    expect(t.widget<CheckboxListTile>(box).value, isFalse);
    await t.tap(box);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('track-save')));
    await settleTracks(t, store);
    final saved = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'sauna');
    expect(saved.prescribed, isTrue);
  });

  testWidgets('medication editor shows Prescribed checked and locked', (t) async {
    await t.runAsync(() async {
      await MedDb.putDef(
        await LocalDb.instance,
        const MedDef(key: 'metformin', label: 'Metformin', doseValue: 500, doseUnit: 'mg'),
      );
    });
    final med = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'med:metformin');
    await mountTracks(t, TrackEditor(store: store, initial: med), height: 2400);
    await settleTracks(t, store);
    final medBox = t.widget<CheckboxListTile>(find.byKey(const ValueKey('track-prescribed')));
    expect(medBox.value, isTrue);
    expect(medBox.onChanged, isNull);
  });

  // why: a track that became prescribed after its experiment started must show
  // no "Skip it" text on the experiment screen.
  // proves: CLAIM(never-ask-skip-prescribed)
  testWidgets('experiment screen of a now-prescribed track lists no skip days', (t) async {
    final custom = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'sauna');
    final started = (await t.runAsync(
      () => store.startExperiment(trackId: 'sauna', startDate: todayLabel(), weeks: 2, seed: 17),
    ))!;
    await mountTracks(
      t,
      ExperimentScreen(
        store: store,
        track: TrackDefinition.fromJson({...custom.toJson(), 'prescribed': true}),
        experimentId: started['id'] as String,
      ),
      height: 2400,
    );
    await settleTracks(t, store);
    expect(find.text('Skip it'), findsNothing);
    expect(find.byKey(const ValueKey('experiment-prescribed')), findsOneWidget);
  });

  testWidgets('experiment screen of an ordinary track lists skip days', (t) async {
    final custom = (await t.runAsync(() => store.definitions()))!.firstWhere((d) => d.id == 'sauna');
    final started = (await t.runAsync(
      () => store.startExperiment(trackId: 'sauna', startDate: todayLabel(), weeks: 2, seed: 17),
    ))!;
    await mountTracks(
      t,
      ExperimentScreen(
        store: store,
        track: custom,
        experimentId: started['id'] as String,
      ),
      height: 2400,
    );
    await settleTracks(t, store);
    expect(find.textContaining('Skip it'), findsWidgets);
  });
}
