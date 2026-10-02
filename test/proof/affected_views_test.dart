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

Widget syncFixture(SyncPresentationState state) => Scaffold(
  body: Padding(
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
  // 8C expanded every section, so at 2x text the long settings lists need
  // taller frames than at 1x to show the whole screen.
  const tallAt2x = {
    'alerts_android': 12400.0,
    'alerts_other_platform': 11900.0,
    'relay_disabled': 9900.0,
    'relay_enabled': 9900.0,
    'gestures_none_selected': 5500.0,
    'gestures_mark_moment_and_flashlight': 5500.0,
  };
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fixture in fixtures.entries) {
        final name = '${fixture.key}_${brightness.name}_${scale.toInt()}x';
        testWidgets(name, (tester) async {
          final boundary = GlobalKey();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(
              390, scale > 1 ? tallAt2x[fixture.key] ?? fixture.value.$1 : fixture.value.$1);
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
          await expectLater(
            find.byKey(boundary),
            matchesGoldenFile('goldens/$name.png'),
          );
          final directory = Platform.environment['EDGE_PROOF_DIR'];
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
}
