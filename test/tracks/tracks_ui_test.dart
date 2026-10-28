import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
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

  // why: review T1. The detail screen of a medication must not offer an
  // experiment, while any other track still does.
  // proves: CLAIM(no-med-experiment)
  testWidgets('medication detail hides Start an experiment; a custom track shows it', (
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
    expect(find.text('Start an experiment'), findsNothing);
    final caffeine = defs.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(t, TrackDetailScreen(key: const ValueKey('c'), store: store, track: caffeine));
    await settleTracks(t, store);
    expect(find.text('Start an experiment'), findsOneWidget);
  });
}
