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

Widget syncFixture(SyncPresentationState state) => Scaffold(
  body: Padding(
    padding: const EdgeInsets.all(24),
    child: SyncControl(state: state, onSync: () {}),
  ),
);

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
    'sync_downloading': (
      300,
      syncFixture(
        const SyncPresentationState(
          phase: 'downloading',
          busy: true,
          contactedBand: true,
        ),
      ),
    ),
    'sync_failed': (
      300,
      syncFixture(
        const SyncPresentationState(
          phase: 'failed',
          error: 'Band disconnected',
        ),
      ),
    ),
    'sync_completed': (
      300,
      syncFixture(
        SyncPresentationState(
          phase: 'completed',
          contactedBand: true,
          lastSuccess: DateTime(2026, 9, 30, 9, 15),
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
        syncPresentation: const SyncPresentationState(
          phase: 'downloading',
          busy: true,
          contactedBand: true,
        ),
        onSync: () {},
      ),
    ),
    'alerts_android': (
      3400,
      const NotificationSettingsView(relaySupported: true),
    ),
    'alerts_other_platform': (
      3400,
      const NotificationSettingsView(relaySupported: false),
    ),
    'relay_disabled': (
      3000,
      const BandNotificationsView(enabled: false, granted: true),
    ),
    'relay_enabled': (
      3000,
      const BandNotificationsView(enabled: true, granted: true),
    ),
    // What an iPhone offers: every in-app action plus ring and flashlight.
    'gestures_none_selected': (
      2200,
      const BandGesturesView(
        chosen: {},
        supported: _gesturesSupported,
      ),
    ),
    'gestures_mark_moment_and_flashlight': (
      2200,
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
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fixture in fixtures.entries) {
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
            expect(find.text('Sync now'), findsOneWidget);
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
