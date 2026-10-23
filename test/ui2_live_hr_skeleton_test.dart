// RED — owner item 10 (ui-feedback-2026-10-22): the LIVE card on the Resting
// heart rate screen (LiveHrCard, lib/ui2/live_hr.dart) must reserve its chart's
// space before the live feed has data, so the chart does not pop in and push
// everything below it down.
//
// Today the card is a different widget at every stage: StatusCard while there
// is no reading, a number-only Surface for the first two readings, and a
// Surface with a 56 pt chart + caption from the third. Each stage has its own
// height, so the content below moves at every step.
//
// Case 4 (not connected): the existing behaviour SHOWS the card (a StatusCard
// "Your band is not connected."), it does not hide it. So that state is pinned
// here too: same size as the loaded card, and it says so quietly.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_edge/ui2/ui2.dart';

const _below = Key('below-the-live-card');
const _arbKey = 'liveHrWaitingSemantics';

String _skeletonLabel() {
  final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
      as Map<String, dynamic>;
  return (arb[_arbKey] as String?) ?? '<missing $_arbKey in app_en.arb>';
}

AppState _app({bool paired = true, bool connected = true}) {
  final app = AppState.forTesting();
  if (paired) app.paired = PairedDevice('r1', 's1', generation: 'gen4');
  app.device.connection = connected ? 'connected' : 'disconnected';
  return app;
}

int _seq = 0;
void _feed(AppState app, int n) {
  for (var i = 0; i < n; i++) {
    final now = DateTime.now().millisecondsSinceEpoch;
    app.debugFeedEngineState(
      '',
      DeviceState()
        ..connection = 'connected'
        ..liveHr = 60 + (_seq % 7)
        ..liveHrAt = now + (++_seq) * 10,
    );
  }
}

Future<void> _pump(WidgetTester t, AppState app, double w) async {
  t.view.physicalSize = Size(w, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(children: [
            LiveHrCard(),
            SizedBox(height: 20),
            SizedBox(key: _below, height: 10, width: 10),
          ]),
        ),
      ),
    ),
  ));
  await t.pump();
}

Rect _card(WidgetTester t) => t.getRect(find.byType(LiveHrCard));
Rect _belowRect(WidgetTester t) => t.getRect(find.byKey(_below));

/// Reference geometry: the card with a full chart.
Future<(Rect, Rect)> _loaded(WidgetTester t, double w) async {
  final app = _app();
  addTearDown(app.dispose);
  _feed(app, 6);
  await _pump(t, app, w);
  return (_card(t), _belowRect(t));
}

void main() {
  for (final w in const [360.0, 390.0]) {
    group('width ${w.toInt()}', () {
      testWidgets('1. before any reading the card is already the loaded size',
          (t) async {
        final (card, below) = await _loaded(t, w);
        final app = _app();
        addTearDown(app.dispose);
        await _pump(t, app, w); // paired + connected, no reading yet
        expect(_card(t), card, reason: 'card rect while waiting');
        expect(_belowRect(t), below,
            reason: 'content below sits where it will finally sit');
      });

      testWidgets('1b. the first one or two readings do not resize it either',
          (t) async {
        final (card, below) = await _loaded(t, w);
        for (final n in [1, 2]) {
          final app = _app();
          addTearDown(app.dispose);
          _feed(app, n);
          await _pump(t, app, w);
          expect(_card(t), card, reason: '$n reading(s): card rect');
          expect(_belowRect(t), below, reason: '$n reading(s): below');
        }
      });

      testWidgets('2. the skeleton is a neutral, chart-sized placeholder',
          (t) async {
        final app = _app();
        addTearDown(app.dispose);
        await _pump(t, app, w);
        final sem = t.ensureSemantics();
        try {

        // Localised: the string lives in app_en.arb and is what is announced.
        final label = _skeletonLabel();
        expect(label.toLowerCase(), contains('live'));
        expect(find.bySemanticsLabel(label), findsOneWidget,
            reason: 'semantics say it is waiting for live data');

        // A drawn frame/axes area of the chart's size (56 pt tall), in the card.
        final area = find.descendant(
          of: find.byType(LiveHrCard),
          matching: find.byWidgetPredicate((x) =>
              x is CustomPaint &&
              x.painter != null &&
              x.painter is! LineChart),
        );
        expect(area, findsWidgets, reason: 'skeleton frame painter');
        final box = t.getRect(area.first);
        expect(box.height, 56);
        expect(box.width, greaterThan(w / 2));
        final ro = t.renderObject<RenderBox>(area.first);
        expect(ro, isNot(paintsNothing), reason: 'frame/axes are drawn');
        expect(ro, isNot(paints..circle()), reason: 'no fake data points');

        // No data line, no scrub, no fake numbers.
        expect(
            find.descendant(
                of: find.byType(LiveHrCard),
                matching: find.byWidgetPredicate(
                    (x) => x is CustomPaint && x.painter is LineChart)),
            findsNothing);
        expect(find.byType(ChartScrub), findsNothing);
        final texts = [
          for (final x in t.widgetList<Text>(find.descendant(
              of: find.byType(LiveHrCard), matching: find.byType(Text))))
            x.data ?? x.textSpan?.toPlainText() ?? ''
        ];
        for (final s in texts) {
          expect(RegExp(r'^\s*\d+\s*$').hasMatch(s), isFalse, reason: s);
          expect(RegExp(r'\d+\s*bpm').hasMatch(s), isFalse, reason: s);
        }
        expect(find.text('LIVE'), findsOneWidget,
            reason: 'the card keeps its LIVE label while waiting');
        } finally {
          sem.dispose();
        }
      });

      testWidgets('3. data replaces the skeleton in place, nothing moves',
          (t) async {
        final app = _app();
        addTearDown(app.dispose);
        await _pump(t, app, w);
        final card = _card(t), below = _belowRect(t);
        final tl = t.getTopLeft(find.byType(LiveHrCard));
        for (var n = 1; n <= 6; n++) {
          _feed(app, 1);
          await t.pump();
          expect(_card(t), card, reason: 'after $n reading(s): card');
          expect(_belowRect(t), below, reason: 'after $n reading(s): below');
          expect(t.getTopLeft(find.byType(LiveHrCard)), tl);
        }
        // The chart is now drawn, at the skeleton's 56 pt, and it is real data.
        final line = find.descendant(
            of: find.byType(LiveHrCard),
            matching: find.byWidgetPredicate(
                (x) => x is CustomPaint && x.painter is LineChart));
        expect(line, findsOneWidget);
        expect(t.getRect(line).height, 56);
        expect(find.bySemanticsLabel(_skeletonLabel()), findsNothing,
            reason: 'the skeleton is gone once the chart is drawn');
      });

      testWidgets('4. not connected / not paired: card stays, same size, quiet',
          (t) async {
        final (card, below) = await _loaded(t, w);
        final off = _app(connected: false);
        addTearDown(off.dispose);
        await _pump(t, off, w);
        expect(find.byType(LiveHrCard), findsOneWidget);
        expect(find.textContaining('not connected'), findsOneWidget);
        expect(_card(t), card, reason: 'disconnected: card rect');
        expect(_belowRect(t), below, reason: 'disconnected: below');

        final unpaired = _app(paired: false, connected: false);
        addTearDown(unpaired.dispose);
        await _pump(t, unpaired, w);
        expect(find.textContaining('No band is paired'), findsOneWidget);
        expect(_card(t), card, reason: 'unpaired: card rect');
        expect(_belowRect(t), below, reason: 'unpaired: below');
      });
    });
  }
}
