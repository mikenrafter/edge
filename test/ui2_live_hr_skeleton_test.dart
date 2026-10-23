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
import 'package:openstrap_edge/l10n/app_localizations.dart';
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

Future<void> _pump(WidgetTester t, AppState app, double w,
    {double scale = 1, String lang = 'en', bool bold = false}) async {
  t.view.physicalSize = Size(w, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), boldText: bold),
        child: child!,
      ),
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
/// The 56 pt plot slot: the chart when loaded, the skeleton before.
Rect _plot(WidgetTester t) {
  final f = find.descendant(
      of: find.byType(LiveHrCard),
      matching: find.byWidgetPredicate((x) =>
          x is CustomPaint && x.painter != null && x is! _Never));
  final rs = [
    for (final e in f.evaluate())
      if (t.getRect(find.byWidget(e.widget)).height >= 56 &&
          t.getRect(find.byWidget(e.widget)).width > 100)
        t.getRect(find.byWidget(e.widget))
  ];
  expect(rs, hasLength(1), reason: 'exactly one plot slot');
  return rs.single;
}

abstract class _Never {}

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
        final plot = _plot(t);
        for (var n = 1; n <= 6; n++) {
          _feed(app, 1);
          await t.pump();
          expect(_card(t), card, reason: 'after $n reading(s): card');
          expect(_belowRect(t), below, reason: 'after $n reading(s): below');
          expect(t.getTopLeft(find.byType(LiveHrCard)), tl);
          expect(_plot(t), plot, reason: 'after $n reading(s): plot');
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

  // ---- fix round (Sol r1) -------------------------------------------------
  // One shared slot structure for every state, at any text scale and locale.
  for (final lang in const ['en', 'ru'])
    for (final w in const [360.0, 390.0])
      for (final sc in const [1.0, 1.3, 2.0, 3.1])
        testWidgets('5. $lang ${w.toInt()}pt x$sc: no overflow; card, plot and '
            'below identical across all states', (t) async {
          final rects = <String, List<Rect>>{};
          Future<void> look(String name, AppState app) async {
            addTearDown(app.dispose);
            await _pump(t, app, w, scale: sc, lang: lang);
            expect(t.takeException(), isNull, reason: '$name: overflow');
            rects[name] = [_card(t), _plot(t), _belowRect(t)];
          }

          await look('loaded', _app()..also((a) => _feed(a, 6)));
          await look('waiting', _app());
          await look('one', _app()..also((a) => _feed(a, 1)));
          await look('two', _app()..also((a) => _feed(a, 2)));
          await look('disconnected', _app(connected: false));
          await look('unpaired', _app(paired: false, connected: false));
          final ref = rects['loaded']!;
          for (final e in rects.entries) {
            expect(e.value[0], ref[0], reason: '${e.key}: card');
            expect(e.value[1], ref[1], reason: '${e.key}: plot');
            expect(e.value[2], ref[2], reason: '${e.key}: below');
          }
        });

  testWidgets('6. connected but no beat: the reason sits inside the plot frame',
      (t) async {
    final app = _app();
    addTearDown(app.dispose);
    await _pump(t, app, 390);
    final why = find.textContaining('No beat in the last');
    expect(why, findsOneWidget);
    final plot = _plot(t);
    expect(plot.contains(t.getRect(why).topLeft) &&
        plot.contains(t.getRect(why).bottomRight), isTrue,
        reason: '${t.getRect(why)} not inside $plot');

    final off = _app(connected: false);
    addTearDown(off.dispose);
    await _pump(t, off, 390);
    final msg = find.textContaining('not connected');
    final plot2 = _plot(t);
    expect(plot2.contains(t.getRect(msg).topLeft) &&
        plot2.contains(t.getRect(msg).bottomRight), isTrue);
  });

  testWidgets('7. the caption is localised: ru waiting + 1-2 readings', (t) async {
    for (final lang in const ['de', 'es', 'fr', 'hi', 'ru', 'zh', 'en']) {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(arb['liveHrStreamNotSaved'], isA<String>(),
          reason: 'app_$lang.arb has liveHrStreamNotSaved');
    }
    final ru = (jsonDecode(File('lib/l10n/app_ru.arb').readAsStringSync())
        as Map<String, dynamic>)['liveHrStreamNotSaved'] as String?;
    expect(ru, isNotNull);
    for (final n in [0, 2]) {
      final app = _app();
      addTearDown(app.dispose);
      if (n > 0) _feed(app, n);
      await _pump(t, app, 390, lang: 'ru');
      expect(find.text(ru ?? '<missing>'), findsOneWidget, reason: '$n readings');
      expect(find.textContaining('The live stream is not saved'), findsNothing);
    }
  });

  // ---- round 3 (Sol r2) ---------------------------------------------------
  // The status reasons must be laid out in full inside the reserved slot, with
  // big text and with the bold-text accessibility setting, in all states.
  for (final lang in const ['en', 'ru'])
    for (final w in const [360.0, 390.0])
      for (final (sc, bold) in const [(3.1, false), (1.0, true), (3.1, true)])
        testWidgets('8. $lang ${w.toInt()}pt x$sc bold=$bold: reasons unclipped, '
            'rects identical', (t) async {
          final rects = <String, List<Rect>>{};
          Future<void> look(String name, AppState app, {String? reason}) async {
            addTearDown(app.dispose);
            await _pump(t, app, w, scale: sc, lang: lang, bold: bold);
            expect(t.takeException(), isNull, reason: '$name: overflow');
            final plot = _plot(t);
            rects[name] = [_card(t), plot, _belowRect(t)];
            if (reason != null) {
              final f = find.textContaining(reason);
              expect(f, findsOneWidget, reason: name);
              final ro = t.renderObject<RenderParagraph>(f);
              final need = ro
                  .getDryLayout(BoxConstraints(maxWidth: ro.constraints.maxWidth))
                  .height;
              expect(ro.size.height, greaterThanOrEqualTo(need - 0.5),
                  reason: '$name: text is squeezed below the $need it needs');
              expect(ro.size.height, lessThanOrEqualTo(plot.height),
                  reason: '$name: text taller than the plot slot');
              expect(t.getRect(f).top, greaterThanOrEqualTo(plot.top - .5));
              expect(t.getRect(f).bottom, lessThanOrEqualTo(plot.bottom + .5));
            }
          }

          await look('loaded', _app()..also((a) => _feed(a, 6)));
          await look('nobeat', _app(), reason: 'No beat in the last');
          await look('one', _app()..also((a) => _feed(a, 1)));
          await look('disconnected', _app(connected: false),
              reason: 'Your band is not connected');
          await look('unpaired', _app(paired: false, connected: false),
              reason: 'No band is paired');
          final ref = rects['loaded']!;
          for (final e in rects.entries) {
            expect(e.value[0], ref[0], reason: '${e.key}: card');
            expect(e.value[1], ref[1], reason: '${e.key}: plot');
            expect(e.value[2], ref[2], reason: '${e.key}: below');
          }
        });
}

extension _Also<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
