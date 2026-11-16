import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show screenForRoute;
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/ui2/screens/pulse_episode.dart';
import 'package:openstrap_edge/ui2/theme.dart';

Future<PulseEpisodeSnapshot> fixture({bool partial = false}) async {
  final random = Random(17);
  const start = 1794449640000, end = start + 17 * 60000;
  final beats = <Map<String, dynamic>>[];
  var time = start - 600000.0;
  var previous = 980.0;
  while (time < end + 600000) {
    final inside = time >= start && time < end;
    final rr = inside
        ? 520 + random.nextDouble() * 700
        : 980 + sin(time / 20000) * 25;
    final i = beats.length;
    final corrected = inside && i % 47 == 0;
    final dropped = partial && time > start + 200000 && time < start + 220000;
    final change = rr - previous;
    beats.add({
      'id': 'b$i',
      'source': 'strap',
      'time': time.round(),
      'index': i,
      'raw': rr,
      'value': dropped
          ? null
          : corrected
          ? 980.0
          : rr,
      'change': i == 0 ? null : change,
      'predecessor': i == 0 ? null : 'b${i - 1}',
      'pair': null,
      'threshold': 330.0,
      'baseline': 980.0,
      'class': corrected ? 'ectopic' : 'normal',
      'plausible': true,
      'retained': !dropped,
      'corrected': corrected,
      'dropped': dropped,
      'feature': !dropped,
      'adjacent': i > 0 && !dropped,
      'labels': [
        if (change > 330) 'suddenLong',
        if (change < -330) 'suddenShort',
        if (corrected) 'corrected',
        if (dropped) 'dropped',
      ],
    });
    previous = rr;
    time += rr;
  }
  final ep = beats
      .where((b) => (b['time'] as num) >= start && (b['time'] as num) < end)
      .toList();
  final input = <String, dynamic>{
    'id': 'strap:$start',
    'source': 'strap',
    'start': start,
    'end': end,
    'ongoing': false,
    'version': 1,
    'alertEligible': true,
    'beats': ep,
    'context': beats,
    'comparison': beats.where((b) => (b['time'] as num) < start).toList(),
    'heartRate': [
      for (var m = 0; m < 480; m++)
        {
          'time': start - 194 * 60000 + m * 60000,
          'bpm': 52 + 6 * sin(m / 70),
          'count': 60,
        },
    ],
    'windows': [
      for (var i = 0; i < 3; i++)
        {
          'pnnPct': 46.0,
          'ratio': .84,
          'coverageMs': 282000,
          'durationMs': 300000,
          'cleaned': 18,
          'total': 300,
        },
    ],
  };
  final encoded = await Isolate.run(() => encodePulseEvidenceHeavy(input));
  final doc =
      (jsonDecode(utf8.decode(gzip.decode(encoded['payload'] as List<int>)))
              as Map)
          .cast<String, dynamic>();
  doc['partial'] = partial;
  if (partial) {
    doc['beats'] = (doc['beats'] as List)
        .where((b) => !(b['dropped'] as bool))
        .toList();
    doc['omissions'] = [
      {
        'from': start + 200000,
        'to': start + 220000,
        'reason': 'evidence limit',
      },
    ];
  }
  return PulseEpisodeSnapshot({
    'id': 'strap:$start',
    'start_ms': start,
    'end_ms': end,
    'day': '2026-11-12',
    'offset_min': 0,
    'ongoing': 0,
    'alert_state': 'sent',
  }, doc);
}

void main() {
  setUpAll(() async {
    for (final family in ['Manrope', '.SF Pro Text']) {
      final loader = FontLoader(family);
      for (final weight in [400, 500, 600, 700, 800]) {
        loader.addFont(
          rootBundle.load('assets/fonts/Manrope/Manrope-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  // WHY/CLAIM(pulse-units): bpm differences transform both endpoints, not the ms delta.
  test('unit conversion and absent values', () {
    expect(pulseValue(1000, PulseUnits.bpm), 60);
    expect(pulseChange({'raw': 1200, 'change': 200}, PulseUnits.bpm), -10);
    expect(pulseValue(0, PulseUnits.bpm), isNull);
    expect(pulseValue(null, PulseUnits.milliseconds), isNull);
  });
  // WHY/CLAIM(pulse-route): notification payload resolves the exact saved episode.
  test('exact notification route', () {
    final screen =
        screenForRoute('/pulse-episode?id=strap%3A123') as PulseEpisodeScreen;
    expect(screen.episodeId, 'strap:123');
    expect(screenForRoute('/pulse-episodes'), isA<PulseEpisodesScreen>());
  });
  // WHY/CLAIM(pulse-upgrade): both episode detail and the row used by
  // Observations explain suppressed history instead of claiming an OS alert.
  // catches: rendering a generic "Alert sent" when no notification was sent.
  testWidgets('upgrade reason appears on episode and Observations row', (
    tester,
  ) async {
    final base = (await tester.runAsync(() => fixture()))!;
    final e = PulseEpisodeSnapshot({
      ...base.row,
      'alert_state': 'sent',
      'alert_reason': 'before this version',
    }, base.evidence);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: PulseEpisodeRow(e)),
      ),
    );
    expect(find.textContaining('before this version'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: PulseEpisodeScreen(episodeId: e.id, snapshot: e),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Already sent: before this version'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['normal', 'partial', 'bpm', 'panned']) {
    // WHY/CLAIM(pulse-v3): actual Flutter screen renders all approved states without layout exceptions.
    testWidgets('dark episode $mode render and interactions', (tester) async {
      tester.view.physicalSize = const Size(430, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final e = (await tester.runAsync(
        () => fixture(partial: mode == 'partial'),
      ))!;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: RepaintBoundary(
            key: boundary,
            child: PulseEpisodeScreen(
              episodeId: e.id,
              snapshot: e,
              initialUnits: mode == 'bpm'
                  ? PulseUnits.bpm
                  : PulseUnits.milliseconds,
              initialZoomMs: mode == 'panned'
                  ? e.startMs + 180000
                  : mode == 'partial'
                  ? e.startMs + 195000
                  : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Each beat against the next'), findsOneWidget);
      expect(find.text('Movement / wear'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('PULSE_SHOTS')) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('pilot-shots').create(recursive: true);
          await File(
            'pilot-shots/$mode.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final before =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: find.byKey(const ValueKey('pulse-zoom')),
                          matching: find.byType(CustomPaint),
                        )
                        .last,
                  )
                  .painter
              as PulseEpisodePainter;
      await tester.drag(
        find.byKey(const ValueKey('pulse-zoom')),
        const Offset(-80, 0),
      );
      await tester.pump();
      final after =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: find.byKey(const ValueKey('pulse-zoom')),
                          matching: find.byType(CustomPaint),
                        )
                        .last,
                  )
                  .painter
              as PulseEpisodePainter;
      expect(after.zoomMs, greaterThan(before.zoomMs));
      await tester.tap(
        find.byKey(const ValueKey('pulse-overview')),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('pulse-zoom')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.text('Raw interval'), findsOneWidget);
      await tester.tap(
        find.text(mode == 'bpm' ? 'ms between beats' : 'beats per minute'),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
