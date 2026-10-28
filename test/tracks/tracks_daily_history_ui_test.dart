// P8a item 3: the Setup history section can say "taken daily since <date>,
// around <time>, <amount>". Widget behaviour first; one golden at the end,
// generated only after the assertions above it pass.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import '../backup/backup_support.dart';
import '../support/bundled_fonts.dart';
import 'ui_support.dart';

// The editor's "today". Everything below is relative to this instant.
final _now = Clock.fixed(DateTime(2026, 10, 27, 12));

Finder _byKeySuffix(String suffix) => find.byWidgetPredicate(
  (w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().endsWith(suffix),
);

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
    env = await BackupEnv.create('tracks_daily_history_ui_p8a.db');
    store = ObservedTracksStore(await LocalDb.instance);
  });
  tearDown(() async => env.dispose());

  Future<TrackDefinition> caffeine(WidgetTester t) async => (await t.runAsync(
    () => store.definitions(),
  ))!.firstWhere((d) => d.id == 'caffeine');

  Future<void> openEditor(WidgetTester t, {double height = 1400}) async {
    await mountTracks(
      t,
      TrackEditor(store: store, initial: await caffeine(t)),
      height: height,
    );
    await settleTracks(t, store);
    await _expand(t, 'Setup history');
  }

  testWidgets('Taken daily adds an ongoing period since today and saves intake', (
    t,
  ) => withClock(_now, () async {
    await openEditor(t);
    await t.ensureVisible(find.byKey(const ValueKey('track-add-daily')));
    await t.tap(find.byKey(const ValueKey('track-add-daily')));
    await t.pumpAndSettle();
    expect(find.text('Daily since Oct 27'), findsOneWidget);
    expect(find.textContaining('Through: ongoing'), findsOneWidget);
    await t.enterText(_byKeySuffix('-around'), '08:00');
    await t.enterText(_byKeySuffix('-amount'), '50');
    await t.pumpAndSettle();
    expect(find.text('Daily since Oct 27 · ~08:00 · 50 mg'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('track-save')));
    await settleTracks(t, store);
    final saved = (await t.runAsync(() => store.history('caffeine')))!;
    expect(saved, hasLength(1));
    final range = saved.single as DoneRange;
    expect(range.startDate, '2026-10-27');
    expect(range.ongoing, isTrue);
    expect(range.intake.approxMinute, 480);
    expect(range.intake.amount!.value, 50);
    expect(
      range.intake.amount!.unit,
      'mg',
      reason: 'the unit is stored with the amount, at entry time',
    );
    expect(t.takeException(), isNull);
  }));

  testWidgets('existing periods list as Daily since / Daily a - b / Not taken', (
    t,
  ) => withClock(_now, () async {
    await t.runAsync(
      () => store.saveHistory('caffeine', [
        NotDoneRange(
          id: 'n',
          trackId: 'caffeine',
          startDate: '2026-01-01',
          endDate: '2026-02-28',
        ),
        DoneRange(
          id: 'd',
          trackId: 'caffeine',
          startDate: '2026-03-01',
          untilDate: '2026-03-20',
          intake: const DailyIntake(approxMinute: 480, amount: DailyAmount(50, 'mg')),
        ),
        DoneRange(
          id: 'o',
          trackId: 'caffeine',
          startDate: '2026-04-01',
          intake: const DailyIntake(approxMinute: 1230),
        ),
      ]),
    );
    await openEditor(t, height: 1800);
    expect(find.text('Not taken Jan 1 – Feb 28'), findsOneWidget);
    expect(find.text('Daily Mar 1 – Mar 20 · ~08:00 · 50 mg'), findsOneWidget);
    expect(find.text('Daily since Apr 1 · ~20:30'), findsOneWidget);
  }));

  testWidgets('a period from another year shows its year', (t) =>
      withClock(_now, () async {
        await t.runAsync(
          () => store.saveHistory('caffeine', [
            DoneRange(
              id: 'o',
              trackId: 'caffeine',
              startDate: '2025-12-01',
              intake: const DailyIntake(),
            ),
          ]),
        );
        await openEditor(t);
        expect(find.text('Daily since Dec 1, 2025'), findsOneWidget);
      }));

  // why: a not-done period cannot carry a time, amount or open end; the UI must
  // not offer fields the model cannot store. Switching a filled period to not
  // done discards them instead of saving a state the type forbids.
  // proves: CLAIM(range-invariants)
  testWidgets('not done offers no time or amount and drops them on save', (
    t,
  ) => withClock(_now, () async {
    await openEditor(t);
    await t.ensureVisible(find.byKey(const ValueKey('track-add-daily')));
    await t.tap(find.byKey(const ValueKey('track-add-daily')));
    await t.pumpAndSettle();
    await t.enterText(_byKeySuffix('-around'), '08:00');
    await t.enterText(_byKeySuffix('-amount'), '50');
    await t.ensureVisible(find.text('Not done'));
    await t.pumpAndSettle();
    await t.tap(find.text('Not done'));
    await t.pumpAndSettle();
    expect(_byKeySuffix('-around'), findsNothing);
    expect(_byKeySuffix('-amount'), findsNothing);
    expect(_byKeySuffix('-ongoing'), findsNothing);
    expect(find.textContaining('Not taken'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('track-save')));
    await settleTracks(t, store);
    final row = (await t.runAsync(
      () async => (await LocalDb.instance).query('track_setup_history'),
    ))!.single;
    expect(row['done'], 0);
    expect(row['approx_minute'], isNull);
    expect(row['amount'], isNull);
    expect(row['amount_unit'], isNull);
  }));

  testWidgets('a time that is not HH:mm blocks the save and keeps the form', (
    t,
  ) => withClock(_now, () async {
    await openEditor(t);
    await t.ensureVisible(find.byKey(const ValueKey('track-add-daily')));
    await t.tap(find.byKey(const ValueKey('track-add-daily')));
    await t.pumpAndSettle();
    await t.enterText(_byKeySuffix('-around'), '25:61');
    await t.tap(find.byKey(const ValueKey('track-save')));
    await settleTracks(t, store);
    expect(
      await t.runAsync(() => store.history('caffeine')),
      isEmpty,
      reason: 'nothing was saved',
    );
    expect(find.byKey(const ValueKey('track-save')), findsOneWidget);
    // The message sits at the top of the lazily built list.
    await t.drag(find.byType(Scrollable).first, const Offset(0, 4000));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-form-error')), findsOneWidget);
  }));

  testWidgets('unchecking ongoing asks for an end and saves a bounded period', (
    t,
  ) => withClock(_now, () async {
    await openEditor(t);
    await t.ensureVisible(find.byKey(const ValueKey('track-add-daily')));
    await t.tap(find.byKey(const ValueKey('track-add-daily')));
    await t.pumpAndSettle();
    await t.ensureVisible(_byKeySuffix('-ongoing'));
    await t.tap(_byKeySuffix('-ongoing'));
    await t.pumpAndSettle();
    expect(find.text('Daily Oct 27 – Oct 27'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('track-save')));
    await settleTracks(t, store);
    final range =
        (await t.runAsync(() => store.history('caffeine')))!.single as DoneRange;
    expect(range.ongoing, isFalse);
    expect(range.untilDate, '2026-10-27');
  }));

  testWidgets('Track editor setup history golden', (t) => withClock(_now, () async {
    await t.runAsync(
      () => store.saveHistory('caffeine', [
        NotDoneRange(
          id: 'n',
          trackId: 'caffeine',
          startDate: '2026-01-01',
          endDate: '2026-02-28',
        ),
        DoneRange(
          id: 'o',
          trackId: 'caffeine',
          startDate: '2026-03-01',
          intake: const DailyIntake(approxMinute: 480, amount: DailyAmount(50, 'mg')),
        ),
      ]),
    );
    await openEditor(t, height: 1400);
    // Fold the (default open) kinetics section so the periods fill the view.
    await _expand(t, 'Timing and kinetics');
    expect(find.text('Daily since Mar 1 · ~08:00 · 50 mg'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_editor_history.png'),
    );
  }), tags: ['golden']);
}
