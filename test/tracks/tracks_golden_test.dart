// Owner approved new goldens for T1. These cover the hub, editable defaults and
// an amount-free timed dose, with bundled production fonts and a fixed clock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
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
