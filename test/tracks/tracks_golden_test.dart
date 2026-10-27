// Owner approved new goldens for T1. These cover the hub, editable defaults and
// an amount-free timed dose, with bundled production fonts and a fixed clock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import '../wake_journal/wake_widgets_test.dart' show sleepFixture;
import '../backup/backup_support.dart';
import '../support/bundled_fonts.dart';
import 'ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  late BackupEnv env;
  late ObservedTracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_goldens_t1.db');
    store = ObservedTracksStore(await LocalDb.instance);
    await store.log(
      TrackEvent(
        id: 'dose',
        trackId: 'caffeine',
        date: '2026-10-26',
        atMs: DateTime.utc(2026, 10, 26, 9).millisecondsSinceEpoch,
        amount: 80,
        subActivityId: 'tea',
      ),
    );
  });
  tearDown(() async => env.dispose());

  testWidgets('Tracks hub golden', (t) async {
    await mountTracks(t, TracksScreen(store: store));
    await settleTracks(t, store);
    expect(find.byKey(const ValueKey('track-card-caffeine')), findsOneWidget);
    expect(
      find.textContaining('Last logged: 2026-10-26 · 09:00 · 80.0 mg'),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/tracks_hub.png'),
    );
  }, tags: ['golden']);

  testWidgets('Track learning status golden', (t) async {
    final caffeine = (await t.runAsync(
      store.definitions,
    ))!.firstWhere((d) => d.id == 'caffeine');
    await t.runAsync(
      () => store.saveDefinition(
        TrackDefinition.fromJson({
          ...caffeine.toJson(),
          'logging_complete': true,
          'logging_complete_since_ms': DateTime.utc(
            2026,
            10,
            27,
          ).millisecondsSinceEpoch,
        }),
      ),
    );
    final saved = (await t.runAsync(
      store.definitions,
    ))!.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(t, TrackDetailScreen(store: store, track: saved));
    await settleTracks(t, store);
    expect(find.text('I log every time'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_learning.png'),
    );
  }, tags: ['golden']);
  testWidgets('Sleep track adjustments golden', (t) async {
    final fixture = sleepFixture();
    final timeline = WakeNightTimeline.forEpoch(
      wakeEpochSec: 1,
      trace: [
        const WakeTraceEntry(
          wakeEpochSec: 1,
          atMs: 1,
          kind: 'natural',
          data: {
            'reason': 'fire',
            'adjustedFor': ['Caffeine 6 h before bed'],
          },
        ),
      ],
    );
    await mountTracks(
      t,
      SleepDetail(
        data: SleepData(
          day: fixture.day,
          night: fixture.night,
          wakeTimeline: timeline,
        ),
      ),
    );
    await settleTracks(t, store);
    expect(find.text('Adjusted for: Caffeine 6 h before bed'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_sleep_adjustments.png'),
    );
  }, tags: ['golden']);
  testWidgets('Track editor golden', (t) async {
    final caffeine = (await t.runAsync(
      () => store.definitions(),
    ))!.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(t, TrackEditor(store: store, initial: caffeine));
    await settleTracks(t, store);
    expect(
      find.byKey(const ValueKey('kinetics-half_life_hours')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_editor.png'),
    );
  }, tags: ['golden']);

  testWidgets('Timed track log golden', (t) async {
    final caffeine = (await t.runAsync(
      () => store.definitions(),
    ))!.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(
      t,
      TrackLogScreen(
        store: store,
        track: caffeine,
        initialAt: DateTime(2026, 10, 26, 21, 15),
      ),
    );
    await settleTracks(t, store);
    expect(find.text('21:15'), findsOneWidget);
    expect(find.text('Amount, optional'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_log.png'),
    );
  }, tags: ['golden']);
  testWidgets('Track detail golden', (t) async {
    final caffeine = (await t.runAsync(
      () => store.definitions(),
    ))!.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(t, TrackDetailScreen(store: store, track: caffeine));
    await settleTracks(t, store);
    expect(find.text('Tea'), findsOneWidget);
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(tracksBoundary),
      matchesGoldenFile('goldens/track_detail.png'),
    );
  }, tags: ['golden']);
}
