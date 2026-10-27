import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';

import '../backup/backup_support.dart';
import '../support/bundled_fonts.dart';
import 'ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  late BackupEnv env;
  late ObservedTracksStore store;
  late TrackDefinition track;
  setUp(() async {
    env = await BackupEnv.create('tracks_t3_goldens.db');
    store = ObservedTracksStore(await LocalDb.instance);
    track = const TrackDefinition(
      id: 'walk',
      name: 'Evening walk',
      icon: 'track',
      kind: 'activity',
      systems: ['hr'],
      roles: ['reminder_aware'],
    );
    await store.saveDefinition(track);
  });
  tearDown(() => env.dispose());

  ActivitySuggestion suggestion({bool prompt = false}) => ActivitySuggestion(
    id: prompt ? 'track:prompt' : 'track:alcohol',
    kind: ActivityKind.values.byName('track'),
    startTs: DateTime.utc(2026, 10, 1, 1).millisecondsSinceEpoch ~/ 1000,
    endTs: DateTime.utc(2026, 10, 1, 3).millisecondsSinceEpoch ~/ 1000,
    revision: 0,
    details: {
      'track_id': 'alcohol',
      'track_name': 'Alcohol',
      'prompt': prompt,
      'evidence':
          'Early sleep heart rate rose while HRV fell compared with your baseline.',
    },
  );

  testWidgets(
    'track evidence review card is a candidate and has track actions',
    (t) async {
      await mountTracks(
        t,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: ActivityProposalCard(
              suggestion: suggestion(),
              onConfirm: () {},
              onEdit: () {},
              onDiscard: () {},
            ),
          ),
        ),
        height: 700,
      );
      expect(find.textContaining('Alcohol'), findsOneWidget);
      expect(find.textContaining('Possible'), findsOneWidget);
      expect(find.text('Change sport'), findsNothing);
      expect(find.textContaining('workout'), findsNothing);
      expect(t.takeException(), isNull);
      await expectLater(
        find.byKey(tracksBoundary),
        matchesGoldenFile('goldens/track_review_candidate.png'),
      );
    },
    tags: ['golden'],
  );

  testWidgets(
    'minimum-count prompt asks instead of presenting a detection time',
    (t) async {
      await mountTracks(
        t,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: ActivityProposalCard(
              suggestion: suggestion(prompt: true),
              onConfirm: () {},
              onDiscard: () {},
            ),
          ),
        ),
        height: 700,
      );
      expect(find.textContaining('Did you'), findsOneWidget);
      expect(find.textContaining('Possible'), findsNothing);
      expect(find.textContaining('120 min'), findsNothing);
      expect(t.takeException(), isNull);
      await expectLater(
        find.byKey(tracksBoundary),
        matchesGoldenFile('goldens/track_missing_prompt.png'),
      );
    },
    tags: ['golden'],
  );

  testWidgets(
    'track detail starts an experiment with a two to four week choice',
    (t) async {
      await mountTracks(t, TrackDetailScreen(store: store, track: track));
      await settleTracks(t, store);
      final action = find.text('Start an experiment');
      expect(action, findsOneWidget);
      await t.ensureVisible(action);
      await t.tap(action);
      await settleTracks(t, store);
      expect(find.text('2 weeks'), findsOneWidget);
      expect(find.text('3 weeks'), findsOneWidget);
      expect(find.text('4 weeks'), findsOneWidget);
      expect(find.textContaining('random'), findsWidgets);
      expect(t.takeException(), isNull);
      await expectLater(
        find.byKey(tracksBoundary),
        matchesGoldenFile('goldens/track_experiment_setup.png'),
      );
    },
    tags: ['golden'],
  );

  testWidgets(
    'running experiment displays assignments and honest pending effect',
    (t) async {
      await t.runAsync(() async {
        await (store as dynamic).startExperiment(
          trackId: track.id,
          startDate: '2026-10-27',
          weeks: 2,
          seed: 17,
        );
      });
      await mountTracks(t, TrackDetailScreen(store: store, track: track));
      await settleTracks(t, store);
      final action = find.text('View experiment');
      expect(action, findsOneWidget);
      await t.ensureVisible(action);
      await t.tap(action);
      await settleTracks(t, store);
      expect(find.textContaining('2026-10-27'), findsWidgets);
      expect(find.textContaining('Running'), findsWidgets);
      expect(find.textContaining('uncertainty'), findsWidgets);
      expect(t.takeException(), isNull);
      await expectLater(
        find.byKey(tracksBoundary),
        matchesGoldenFile('goldens/track_experiment_running.png'),
      );
    },
    tags: ['golden'],
  );
}
