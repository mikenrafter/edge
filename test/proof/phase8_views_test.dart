// Phase 8 proof views. Synthetic fixtures; no device or personal data.
// Same capture rules as affected_views_test.dart: bundled fonts, committed
// baselines under goldens/phase8_*.png. Pictures are kept for the PAINTER
// fixtures (1x and 2x text) and one showcase screen (1x); the other screens
// have structural tests at the bottom of this file.
//
// The baselines do not exist yet: they are generated after implementation
// (`flutter test --update-goldens test/proof/phase8_views_test.dart`) and
// reviewed before they are committed. Until then every case fails red.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/live_devices.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'affected_views_test.dart' show loadFonts;
import 'structure_harness.dart';

final _t0 = DateTime(2026, 10, 2, 9, 0, 0);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));
int _ts(int minute) =>
    DateTime(2026, 9, 30, 9, minute).millisecondsSinceEpoch ~/ 1000;

LiveStreamBuffer _buffer() {
  final b = LiveStreamBuffer();
  for (var i = 0; i < 30; i++) {
    b.add('band', 'hr', _at(10000 + i * 1000), 60 + (i % 7).toDouble());
    b.add('band', 'accel_x', _at(10000 + i * 1000), ((i % 5) - 2) / 10);
  }
  b.add('band', 'skin_temp', _at(0), 33.4);
  return b;
}

typedef _Act = Future<void> Function(WidgetTester t);

Widget _timeline() => Scaffold(
      body: Builder(
        builder: (c) => ListView(
          padding: const EdgeInsets.all(16),
          children: timelineBody(
            c,
            TimelineData(
              day: '2026-09-30',
              moments: dayMoments(timeline: {
                'events': [
                  for (var i = 0; i < 5; i++) {'event_id': 14, 'ts': _ts(i)},
                  {'event_id': 7, 'ts': _ts(20)},
                  {'event_id': 14, 'ts': _ts(40)},
                ],
              }),
            ),
          ),
        ),
      ),
    );

Widget _scrub() => Scaffold(
      body: Center(
        child: SizedBox(
          width: 340,
          height: 300,
          child: ChartScrub(
            label: 'Heart rate',
            gaps: true,
            time: (at) =>
                '${(7 + ChartScrub.slotAt(5, at)).toString().padLeft(2, '0')}:00',
            keys: [
              ChartKey.slots('Heart rate (bpm)', const Color(0xFFE5484D),
                  const [58, 61, null, 66, 64], (i, v) => '${v.round()} bpm'),
            ],
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChart(
                  const [58, 61, null, 66, 64], const Color(0xFFE5484D)),
            ),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadFonts);
  final fixtures = <String, (double, Widget, _Act?)>{
    'live_devices': (
      2400,
      LiveDevicesView(
        now: _at(40000),
        buffer: _buffer(),
        devices: [
          const LiveDevice(
              id: 'band',
              name: 'Synthetic band',
              kind: 'WHOOP 4.0',
              connected: true,
              batteryPct: 78),
          LiveDevice(
              id: 'polar',
              name: 'Synthetic chest strap',
              kind: 'Chest strap',
              connected: false,
              lastSeen: _at(12000)),
        ],
      ),
      null,
    ),
    'device_lab_mg': (
      2000,
      DeviceLabView(
        ecgSupported: true,
        ecgOnDoubleTap: true,
        onEcgOnDoubleTap: (_) {},
        repeatWindowMs: 2500,
        onRepeatWindowMs: (_) {},
        sessions: const [
          'ECG sensor touches | start 300 ms, gap 200 ms, confirm 200 ms | '
              '3 taps | 6.4 s in total',
        ],
        steps: const [
          '09:15:09.650 | tap +6400 ms | last +40 ms | Session ended: ECG '
              'sensor touches | start 300 ms, gap 200 ms, confirm 200 ms | 3 '
              'taps | 6.4 s in total',
          '09:15:09.610 | tap +6360 ms | last +900 ms | Final count 3 at sample '
              'time 1002600 ms.',
          '09:15:04.690 | tap +1440 ms | last +30 ms | Acknowledgement '
              'written, 1440 ms after the tap (260 ms after the request).',
          '09:15:04.660 | tap +1410 ms | last +10 ms | Stream is steady, 1180 '
              'ms after the tap (two packets within 1500 ms of each other).',
          '09:15:03.480 | tap +230 ms | last +30 ms | Packet 1: 100 samples, 0 '
              'with contact, strap time 1787823784.000, first packet',
          '09:15:03.250 | tap +0 ms | last +0 ms | Double tap received. '
              'Starting the ECG stream.',
        ],
      ),
      null,
    ),
    'device_lab_no_ecg': (
      2000,
      const DeviceLabView(ecgSupported: false),
      null,
    ),
    'buzz_pattern': (
      900,
      Scaffold(
        body: BuzzPatternSheet(bandConnected: true, onPlay: (_) async => true, onSave: (_) {}),
      ),
      null,
    ),
    'collapsed_taps': (1400, _timeline(), null),
    'gestures_draft_taps_no_ecg': (
      2600,
      const BandGesturesView(
        chosen: {DeviceAction.markMoment},
        supported: {DeviceAction.none, DeviceAction.markMoment, DeviceAction.torch},
        ecgSupported: false,
      ),
      null,
    ),
    'gestures_tap_method_mg': (
      3000,
      BandGesturesView(
        chosen: const {DeviceAction.markMoment},
        supported: const {
          DeviceAction.none,
          DeviceAction.markMoment,
          DeviceAction.torch,
        },
        ecgSupported: true,
        tapMethod: TapCountMethod.repeat,
        repeatWindowMs: 2500,
        onRepeatWindowMs: (_) {},
        onTapMethod: (_) {},
      ),
      null,
    ),
    'chart_scrub_readout': (
      400,
      _scrub(),
      (t) async {
        final box = t.getTopLeft(find.byType(ChartScrub));
        await t.tapAt(box + const Offset(340 * 0.25, 80));
      },
    ),
  };
  // PAINTER fixtures are pictures at 1x and 2x text: their point is pixels.
  // Showcase screens are pictures at 1x only. Every other screen is covered by
  // the structural tests below. See docs/proof-workflow.md.
  const painters = {'live_devices', 'chart_scrub_readout'};
  const showcase = {'buzz_pattern'};
  final proofDir = Platform.environment['EDGE_PROOF_DIR'];
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fixture in fixtures.entries) {
        final isPainter = painters.contains(fixture.key);
        final pictured = isPainter || showcase.contains(fixture.key);
        if (scale > 1 && !isPainter) continue;
        // A non-pictured screen is only drawn here to feed the proof capture.
        if (!pictured && proofDir == null) continue;
        final name =
            'phase8_${fixture.key}_${brightness.name}_${scale.toInt()}x';
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
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(key: boundary, child: fixture.value.$2),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          if (fixture.value.$3 case final act?) {
            await act(tester);
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull);
          if (pictured) {
            await expectLater(
              find.byKey(boundary),
              matchesGoldenFile('goldens/$name.png'),
            );
          }
          final directory = proofDir;
          if (directory != null) {
            await tester.runAsync(() async {
              final render = boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final data =
                  await image.toByteData(format: ui.ImageByteFormat.png);
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

  // Structural cover for the SCREEN fixtures that have no picture.
  screenStructure('device_lab_mg', fixtures['device_lab_mg']!.$2, () {
    expect(find.text('Device lab'), findsOneWidget);
    expect(find.text('ECG on double tap'), findsOneWidget);
    expect(find.text('Touch windows'), findsOneWidget);
    expect(find.text('Start threshold'), findsOneWidget);
    expect(find.text('Gap threshold'), findsOneWidget);
    expect(find.text('Confirmation threshold'), findsOneWidget);
    // The ECG row is usable on an MG band.
    expect(find.text('This band has no ECG sensor'), findsNothing);
  });
  screenStructure('device_lab_no_ecg', fixtures['device_lab_no_ecg']!.$2, () {
    expect(find.text('Device lab'), findsOneWidget);
    expect(find.text('ECG on double tap'), findsOneWidget);
    expect(find.text('This band has no ECG sensor'), findsOneWidget);
    expect(find.text('Touch windows'), findsOneWidget);
  });
  screenStructure('collapsed_taps', fixtures['collapsed_taps']!.$2, () {
    expect(find.text('What happened'), findsOneWidget);
    // Five double taps in a row collapse to one row with a count.
    expect(find.text('You double-tapped the band · 5 times'), findsOneWidget);
    expect(find.text('You double-tapped the band'), findsOneWidget);
    expect(find.text('On the charger'), findsOneWidget);
  });
  screenStructure(
      'gestures_draft_taps_no_ecg', fixtures['gestures_draft_taps_no_ecg']!.$2,
      () {
    expect(find.text('Gestures'), findsOneWidget);
    expect(find.text('Count extra taps with'), findsOneWidget);
    expect(find.text('ECG sensor touches'), findsOneWidget);
    expect(find.text('This band has no ECG sensor'), findsOneWidget);
    expect(find.text('More double taps'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget, reason: 'the count tabs');
    expect(find.text('What needs a WHOOP MG'), findsOneWidget);
  });
  screenStructure(
      'gestures_tap_method_mg', fixtures['gestures_tap_method_mg']!.$2, () {
    expect(find.text('Gestures'), findsOneWidget);
    expect(find.text('Count extra taps with'), findsOneWidget);
    expect(find.text('ECG sensor touches'), findsOneWidget);
    expect(find.text('This band has no ECG sensor'), findsNothing);
    expect(find.text('×2'), findsOneWidget, reason: 'the count tabs');
    expect(find.text('What needs a WHOOP MG'), findsOneWidget);
  });
}
