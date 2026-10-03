// Synthetic fixtures for the controls roadmap. No device or personal data.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/demo/demo_mode_banner.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'structure_harness.dart';

Future<void> loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  for (final entry in {
    'Manrope': 'Manrope',
    '.SF Pro Text': 'Manrope',
    'Barlow Condensed': 'BarlowCondensed',
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final file in Directory(
      'assets/fonts/${entry.value}',
    ).listSync().whereType<File>()) {
      if (file.path.endsWith('.ttf')) {
        loader.addFont(
          file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      }
    }
    await loader.load();
  }
}

final _syncT0 = DateTime(2026, 9, 30, 9, 15);

/// The time the sync panels are drawn at: 75 s into a running sync.
DateTime _syncNow() => _syncT0.add(const Duration(seconds: 75));

// Scrollable, as the panel is on a real page: on a short phone at large text
// it is taller than the screen and must scroll, not overflow.
Widget syncFixture(SyncPresentationState state) => Scaffold(
  body: SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    // Top-aligned so the panel is as tall as its content, not the fixture.
    child: Align(
      alignment: Alignment.topCenter,
      child: SyncControl(state: state, onSync: () {}, clock: _syncNow),
    ),
  ),
);

SyncStep _s(
  SyncStepId id,
  SyncStepStatus status, {
  int? start,
  int? end,
  String? note,
  SyncDownloadDetail? download,
  SyncCalculateDetail? calculate,
}) => SyncStep(
  id: id,
  status: status,
  startedAt: start == null ? null : _syncT0.add(Duration(seconds: start)),
  endedAt: end == null ? null : _syncT0.add(Duration(seconds: end)),
  note: note,
  download: download,
  calculate: calculate,
);

SyncPresentationState _running(List<SyncStep> steps, String phase) =>
    SyncPresentationState(
      phase: phase,
      busy: true,
      contactedBand: true,
      startedAt: _syncT0,
      steps: steps,
    );

final _downloadingState = _running([
  _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 2),
  _s(
    SyncStepId.download,
    SyncStepStatus.running,
    start: 2,
    download: SyncDownloadDetail(
      records: 12400,
      chunks: 31,
      syncedThrough: DateTime(2026, 9, 29, 22, 15),
      bandNewest: DateTime(2026, 9, 30, 8, 45),
    ),
  ),
  _s(SyncStepId.calculate, SyncStepStatus.waiting),
  _s(SyncStepId.done, SyncStepStatus.waiting),
], 'downloading');

SyncPresentationState _calculatingState(SyncCalculateDetail d) => _running([
  _s(
    SyncStepId.connect,
    SyncStepStatus.skipped,
    note: 'Already connected',
  ),
  _s(
    SyncStepId.download,
    SyncStepStatus.done,
    start: 0,
    end: 58,
    download: SyncDownloadDetail(
      records: 41800,
      chunks: 104,
      syncedThrough: DateTime(2026, 9, 30, 9, 10),
    ),
  ),
  _s(SyncStepId.calculate, SyncStepStatus.running, start: 58, calculate: d),
  _s(SyncStepId.done, SyncStepStatus.waiting),
], 'deriving');

const _gesturesSupported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.workoutToggle,
  DeviceAction.logWater,
  DeviceAction.ringPhone,
  DeviceAction.torch,
};

void main() {
  setUpAll(loadFonts);
  final fixtures = <String, (double, Widget)>{
    'sync_offline': (300, syncFixture(const SyncPresentationState())),
    'sync_downloading': (1300, syncFixture(_downloadingState)),
    'sync_calculating': (
      1300,
      syncFixture(
        _calculatingState(
          const SyncCalculateDetail(
            dayIndex: 2,
            dayTotal: 5,
            day: '2026-09-29',
          ),
        ),
      ),
    ),
    'sync_waiting': (
      1300,
      syncFixture(_calculatingState(const SyncCalculateDetail(waiting: true))),
    ),
    'sync_failed': (
      1300,
      syncFixture(
        SyncPresentationState(
          phase: 'failed',
          error: 'Bad state: Band disconnected during sync',
          failureReason: 'Band disconnected during sync',
          lastSuccess: DateTime(2026, 9, 29, 7, 40),
          startedAt: _syncT0,
          finishedAt: _syncT0.add(const Duration(seconds: 41)),
          steps: [
            _s(SyncStepId.connect, SyncStepStatus.done, start: 0, end: 3),
            _s(
              SyncStepId.download,
              SyncStepStatus.failed,
              start: 3,
              end: 41,
              download: const SyncDownloadDetail(records: 2200, chunks: 6),
            ),
            _s(
              SyncStepId.calculate,
              SyncStepStatus.skipped,
              note: 'Not reached',
            ),
            _s(SyncStepId.done, SyncStepStatus.skipped, note: 'Not reached'),
          ],
        ),
      ),
    ),
    'sync_completed': (
      1300,
      syncFixture(
        SyncPresentationState(
          phase: 'completed',
          contactedBand: true,
          lastSuccess: DateTime(2026, 9, 30, 9, 15),
          startedAt: _syncT0.subtract(const Duration(seconds: 70)),
          finishedAt: _syncT0,
          steps: [
            _s(SyncStepId.connect, SyncStepStatus.done, start: -70, end: -67),
            _s(
              SyncStepId.download,
              SyncStepStatus.done,
              start: -67,
              end: -20,
              download: SyncDownloadDetail(
                records: 41800,
                chunks: 104,
                syncedThrough: DateTime(2026, 9, 30, 9, 10),
              ),
            ),
            _s(
              SyncStepId.calculate,
              SyncStepStatus.done,
              start: -20,
              end: 0,
              calculate: const SyncCalculateDetail(
                dayIndex: 5,
                dayTotal: 5,
                day: '2026-09-26',
              ),
            ),
            _s(SyncStepId.done, SyncStepStatus.done, start: 0, end: 0),
          ],
        ),
      ),
    ),
    'sleep_empty': (
      2000,
      const SleepDetail(data: SleepData(day: '2026-09-30')),
    ),
    'sleep_asserted_without_metrics': (
      2000,
      SleepDetail(
        data: SleepData(
          day: '2026-09-30',
          night: {
            'sleep_source': 'manual',
            'onset_ts':
                DateTime(2026, 9, 29, 10).millisecondsSinceEpoch ~/ 1000,
            'wake_ts': DateTime(2026, 9, 29, 18).millisecondsSinceEpoch ~/ 1000,
          },
        ),
      ),
    ),
    // The one Recalculate button lives inside this card (not in a strip above).
    'sleep_inferred_window': (
      2000,
      SleepDetail(
        data: SleepData(
          day: '2026-09-30',
          night: {
            'sleep_source': 'auto_fallback',
            'onset_ts':
                DateTime(2026, 9, 29, 23, 10).millisecondsSinceEpoch ~/ 1000,
            'wake_ts': DateTime(2026, 9, 30, 6, 40).millisecondsSinceEpoch ~/ 1000,
          },
        ),
      ),
    ),
    'primary_band_sync': (
      2400,
      DeviceDetailView(
        const HealthSource(
          name: 'Synthetic band',
          kind: 'WHOOP 4',
          tier: null,
          icon: Icons.watch,
          connected: true,
          isBand: true,
          family: 'gen4',
        ),
        syncPresentation: _downloadingState,
        syncClock: _syncNow,
        onSync: () {},
      ),
    ),
    'alerts_android': (
      5100,
      const NotificationSettingsView(relaySupported: true),
    ),
    'alerts_other_platform': (
      4950,
      const NotificationSettingsView(relaySupported: false),
    ),
    'relay_disabled': (
      3700,
      const BandNotificationsView(enabled: false, granted: true),
    ),
    'relay_enabled': (
      3700,
      const BandNotificationsView(enabled: true, granted: true),
    ),
    // What an iPhone offers: every in-app action plus ring and flashlight.
    'gestures_none_selected': (
      1800,
      const BandGesturesView(
        chosen: {},
        supported: _gesturesSupported,
      ),
    ),
    'gestures_mark_moment_and_flashlight': (
      1800,
      BandGesturesView(
        chosen: const {DeviceAction.markMoment, DeviceAction.torch},
        supported: _gesturesSupported,
        replay: const {DeviceAction.markMoment},
        onToggle: (_, _) {},
        onReplay: (_, _) {},
      ),
    ),
    'demo_disclosure': (
      300,
      const Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: DemoModeBanner()),
      ),
    ),
  };
  // SCREEN fixtures. Showcase screens keep a light/dark picture at 1x text;
  // every other screen is covered by the structural tests below instead of a
  // PNG. See docs/proof-workflow.md, "Regenerating goldens".
  const showcase = {'alerts_android', 'primary_band_sync'};
  final proofDir = Platform.environment['EDGE_PROOF_DIR'];
  for (final brightness in Brightness.values) {
    for (final scale in [1.0]) {
      for (final fixture in fixtures.entries) {
        // A non-showcase screen is only drawn here to feed the proof capture.
        if (!showcase.contains(fixture.key) && proofDir == null) continue;
        final name = '${fixture.key}_${brightness.name}_${scale.toInt()}x';
        testWidgets(name, (tester) async {
          final boundary = GlobalKey();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(390, fixture.value.$1);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(key: boundary, child: fixture.value.$2),
            ),
          );
          // A busy spinner never settles. Two bounded pumps allow layout and
          // font completion while keeping the captured animation deterministic.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          if (fixture.key.startsWith('sync_') ||
              fixture.key == 'primary_band_sync') {
            // One control: "Sync now", or "Retry" once the last attempt failed.
            expect(
              find.text(fixture.key == 'sync_failed' ? 'Retry' : 'Sync now'),
              findsOneWidget,
            );
          }
          if (fixture.key.startsWith('sleep_')) {
            expect(find.text('Recalculate this night'), findsOneWidget);
          }
          if (fixture.key == 'alerts_other_platform') {
            expect(find.text('Android Relay'), findsNothing);
          }
          if (showcase.contains(fixture.key)) {
            await expectLater(
              find.byKey(boundary),
              matchesGoldenFile('goldens/$name.png'),
            );
          }
          final directory = proofDir;
          if (directory != null) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final output = File('$directory/$name.png');
              await output.parent.create(recursive: true);
              await output.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }

  // Structural cover for every SCREEN fixture that has no picture. Each entry
  // names what the screen must show; the harness adds the overflow sweep.
  const syncSteps = ['Connect', 'Download', 'Calculate', 'Done'];
  void syncSteps_() {
    for (final step in syncSteps) {
      expect(find.text(step), findsOneWidget, reason: '$step step missing');
    }
  }

  screenStructure('sync_offline', fixtures['sync_offline']!.$2, () {
    expect(find.text('Band sync'), findsOneWidget);
    expect(find.text('Local data refreshed. Band not contacted.'),
        findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    // No run, no step list.
    expect(find.text('Download'), findsNothing);
  });
  screenStructure('sync_downloading', fixtures['sync_downloading']!.$2, () {
    expect(find.text('Syncing with your band'), findsOneWidget);
    syncSteps_();
    expect(find.text('12,400 records · 31 chunks'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
  });
  screenStructure('sync_calculating', fixtures['sync_calculating']!.$2, () {
    expect(find.text('Syncing with your band'), findsOneWidget);
    syncSteps_();
    expect(find.text('Day 2 of 5 · 2026-09-29'), findsOneWidget);
    expect(find.text('Already connected'), findsOneWidget);
  });
  screenStructure('sync_waiting', fixtures['sync_waiting']!.$2, () {
    syncSteps_();
    expect(find.text('Waiting for another calculation to finish'),
        findsOneWidget);
  });
  screenStructure('sync_failed', fixtures['sync_failed']!.$2, () {
    expect(find.text('Sync failed'), findsOneWidget);
    syncSteps_();
    expect(find.text('Band disconnected during sync'), findsOneWidget);
    expect(find.text('Last successful sync: 7:40 AM'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });
  screenStructure('sync_completed', fixtures['sync_completed']!.$2, () {
    expect(find.text('Sync completed'), findsOneWidget);
    syncSteps_();
    expect(find.text('Day 5 of 5 · 2026-09-26'), findsOneWidget);
    expect(find.text('Last successful sync: 9:15 AM'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
  });
  screenStructure('sleep_empty', fixtures['sleep_empty']!.$2, () {
    expect(find.text('No night to show'), findsOneWidget);
    expect(find.text('Recalculate this night'), findsOneWidget);
    expect(find.text('Set the times myself'), findsOneWidget);
    expect(find.text('Naps'), findsOneWidget);
  });
  screenStructure(
      'sleep_asserted_without_metrics', fixtures['sleep_asserted_without_metrics']!.$2,
      () {
    expect(find.text('You set this window'), findsOneWidget);
    expect(find.text('Your times, no sleep numbers'), findsOneWidget);
    expect(find.text('Recalculate this night'), findsOneWidget);
    expect(find.text('Back to automatic'), findsOneWidget);
    // Honesty: no empty-night copy beside a window the user asserted.
    expect(find.text('No night to show'), findsNothing);
  });
  screenStructure('sleep_inferred_window', fixtures['sleep_inferred_window']!.$2, () {
    expect(find.text('This window was inferred from heart rate'),
        findsOneWidget);
    expect(find.text('Recalculate this night'), findsOneWidget);
    expect(find.text('These times are right'), findsOneWidget);
    expect(find.text('Set the times myself'), findsOneWidget);
  });
  screenStructure('alerts_other_platform', fixtures['alerts_other_platform']!.$2,
      () {
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Alarms & Wake'), findsOneWidget);
    expect(find.text('Alarm not confirmed'), findsOneWidget);
    expect(find.text('Recovery ready'), findsOneWidget);
    expect(find.text('Detected workouts'), findsOneWidget);
    // The Android-only relay section is absent, not disabled.
    expect(find.text('Android Relay'), findsNothing);
  });
  screenStructure('relay_disabled', fixtures['relay_disabled']!.$2, () {
    expect(find.text('Buzz on app notifications'), findsOneWidget);
    expect(find.text('Only buzz while worn'), findsOneWidget);
    expect(find.text('Apps that can buzz'), findsOneWidget);
    expect(find.text('Turn on the relay first'), findsOneWidget);
    expect(find.text('Buzz pattern'), findsWidgets);
  });
  screenStructure('relay_enabled', fixtures['relay_enabled']!.$2, () {
    expect(find.text('Buzz on app notifications'), findsOneWidget);
    expect(find.text('Apps that can buzz'), findsOneWidget);
    expect(find.text('No app has notified you yet'), findsOneWidget);
    expect(find.text('Turn on the relay first'), findsNothing);
    expect(find.text('Buzz pattern'), findsWidgets);
  });
  screenStructure('gestures_none_selected', fixtures['gestures_none_selected']!.$2,
      () {
    expect(find.text('Gestures'), findsOneWidget);
    for (final action in const [
      'Mark a moment',
      'Start / stop workout',
      'Log water',
      'Ring my phone',
      'Flashlight',
    ]) {
      expect(find.text(action), findsOneWidget, reason: '$action missing');
    }
    // Nothing chosen: the replay option is explained, not offered.
    expect(find.text('Turn on Mark a moment first'), findsOneWidget);
    expect(find.text('Count extra taps with'), findsOneWidget);
  });
  screenStructure('gestures_mark_moment_and_flashlight',
      fixtures['gestures_mark_moment_and_flashlight']!.$2, () {
    expect(find.text('Mark a moment'), findsOneWidget);
    expect(find.text('Flashlight'), findsOneWidget);
    expect(find.text('Also run for taps replayed from history'),
        findsOneWidget);
    expect(find.text('Turn on Mark a moment first'), findsNothing);
  });
  screenStructure('demo_disclosure', fixtures['demo_disclosure']!.$2, () {
    expect(find.text('Demo mode. All data on screen is generated sample data.'),
        findsOneWidget);
    expect(find.text('Exit'), findsOneWidget);
  });
}
