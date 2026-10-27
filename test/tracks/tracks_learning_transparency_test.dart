import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_trace_text.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import '../wake_journal/wake_widgets_test.dart' show sleepFixture, pumpWakePage;
import '../backup/backup_support.dart';
import 'ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late ObservedTracksStore store;
  setUp(() async {
    env = await BackupEnv.create('track_transparency_t2.db');
    store = ObservedTracksStore(await LocalDb.instance);
  });
  tearDown(() => env.dispose());
  test('trace explains the adjustments actually used on this occurrence', () {
    final lines = describeWakeTrace([
      const WakeTraceEntry(
        wakeEpochSec: 1,
        atMs: 1,
        kind: 'natural',
        data: {
          'reason': 'policyHold',
          'adjustedFor': ['Caffeine 6 h before bed'],
        },
      ),
    ]);
    expect(lines, contains('Adjusted for: Caffeine 6 h before bed'));
  });
  testWidgets('sleep detail renders adjustments from its own wake trace', (
    t,
  ) async {
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
        const WakeTraceEntry(
          wakeEpochSec: 2,
          atMs: 2,
          kind: 'natural',
          data: {
            'reason': 'fire',
            'adjustedFor': ['Wrong night'],
          },
        ),
      ],
    );
    await pumpWakePage(
      t,
      SleepDetail(
        data: SleepData(
          day: fixture.day,
          night: fixture.night,
          wakeTimeline: timeline,
        ),
      ),
    );
    expect(find.text('Adjusted for: Caffeine 6 h before bed'), findsOneWidget);
    expect(find.textContaining('Wrong night'), findsNothing);
  });
  testWidgets('completeness acknowledgement persists from the track detail', (
    t,
  ) async {
    final defs = (await t.runAsync(store.definitions))!;
    final track = defs.firstWhere((d) => d.id == 'caffeine');
    await mountTracks(t, TrackDetailScreen(store: store, track: track));
    await settleTracks(t, store);
    expect(find.text('I log every time'), findsOneWidget);
    await t.tap(find.text('I log every time'));
    await settleTracks(t, store);
    final saved = await t.runAsync(store.definitions);
    expect(
      saved!.firstWhere((d) => d.id == 'caffeine').toJson()['logging_complete'],
      true,
    );
    expect(find.text('None today?'), findsOneWidget);
    expect(find.byKey(const ValueKey('track-learning-status')), findsOneWidget);
  });
}
