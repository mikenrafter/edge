// Synthetic Home fixtures. The pictures cover the rings, Natural Wake and the
// activity review together; the geometry checks pin their spacing separately.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/natural_wake_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/bundled_fonts.dart';

const _phone = Size(412, 915);
const _boundary = ValueKey('home-wake-golden');
final _rings = find.byKey(const ValueKey('card:rings'));
final _wake = find.byKey(const ValueKey('card:wake'));
final _review = find.byKey(const ValueKey('card:detected'));
final _now = DateTime(2026, 10, 25, 9);

const _data = HomeData(
  name: 'Alex',
  readiness: Metric(value: 80, confidence: .9, tier: MetricTier.high),
  strain: Metric(value: 5, confidence: .9, tier: MetricTier.high),
  sleepMin: Metric(value: 450, confidence: .9, tier: MetricTier.high),
  sleepNeedMin: Metric(value: 480, confidence: .9, tier: MetricTier.high),
  rhr: Metric(value: 52, confidence: .9, tier: MetricTier.high),
  steps: Metric(value: 1800, confidence: .9, tier: MetricTier.high),
  pendingActivities: 2,
);

Future<AppState> _home(WidgetTester t, {required bool buzzing}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = _phone;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  final locale = LocaleController.seed('en');
  app.wake.noteNaturalRepeat(buzzing);
  addTearDown(() async {
    await t.pumpWidget(const SizedBox.shrink());
    app.dispose();
    locale.dispose();
  });
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LocaleController>.value(value: locale),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: RepaintBoundary(
        key: _boundary,
        child: Scaffold(body: HomeScreen(data: _data, hour: 9, now: _now)),
      ),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  expect(t.takeException(), isNull);
  return app;
}

Future<void> _frameCards(WidgetTester t) async {
  // Keep the whole rings card and both neighbours in the phone screenshot.
  final position = t.state<ScrollableState>(find.byType(Scrollable).first).position;
  position.jumpTo((position.pixels + t.getRect(_rings).top - S.x5)
      .clamp(0.0, position.maxScrollExtent));
  await t.pump();
  final viewport = Offset.zero & _phone;
  for (final card in [_rings, _review, if (_wake.evaluate().isNotEmpty) _wake]) {
    final rect = t.getRect(card);
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
  }
  expect(t.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({
      'nudge.discord.dismissed': true,
      'nudge.donate.dismissed': true,
    });
    await Prefs.ensureLoaded();
  });

  testWidgets('Home buzzing wake card sits directly above activity review with '
      'S.x3 gaps and matching margins', (t) async {
    await _home(t, buzzing: true);
    await _frameCards(t);
    expect(find.text('Review activities'), findsOneWidget);
    expect(find.byKey(const ValueKey('natural-wake-im-up')), findsOneWidget);
    final rings = t.getRect(_rings);
    final wake = t.getRect(_wake);
    final review = t.getRect(_review);
    expect(wake.top - rings.bottom, closeTo(S.x3, .001));
    expect(review.top - wake.bottom, closeTo(S.x3, .001));
    expect(wake.left, S.x4);
    expect(wake.right, _phone.width - S.x4);
    expect(wake.left, review.left);
    expect(wake.right, review.right);
    final headline = t.getRect(find.byKey(const ValueKey('natural-wake-buzzing')));
    expect(headline.left - wake.left, S.x4);
    expect(headline.top - wake.top, S.x4);
  });

  testWidgets('Home idle wake adds no gap and stopping restores review position',
      (t) async {
    final app = await _home(t, buzzing: false);
    final idleReviewTop = t.getRect(_review).top;
    final idleRings = t.getRect(_rings);
    expect(_wake, findsNothing);
    expect(find.byType(NaturalWakeBuzzingCard), findsNothing);
    expect(idleReviewTop - idleRings.bottom, closeTo(S.x3, .001));

    app.wake.noteNaturalRepeat(true);
    await t.pump();
    final wake = t.getRect(_wake);
    expect(t.getRect(_rings), idleRings,
        reason: 'buzzing must not move the header, day switcher or rings');
    expect(t.getRect(_review).top - idleReviewTop,
        closeTo(wake.height + S.x3, .001));
    expect(t.getRect(_review).top - wake.bottom, closeTo(S.x3, .001));

    app.wake.noteNaturalRepeat(false);
    await t.pump();
    expect(_wake, findsNothing);
    expect(find.byKey(const ValueKey('natural-wake-im-up')), findsNothing);
    expect(t.getRect(_review).top, idleReviewTop);
    expect(t.takeException(), isNull);
  });

  testWidgets('Home Natural Wake buzzing golden', (t) async {
    await _home(t, buzzing: true);
    await _frameCards(t);
    expect(_wake, findsOneWidget);
    expect(find.text('Review activities'), findsOneWidget);
    await expectLater(find.byKey(_boundary),
        matchesGoldenFile('goldens/home_wake_card_buzzing.png'));
  });

  testWidgets('Home Natural Wake idle golden', (t) async {
    await _home(t, buzzing: false);
    await _frameCards(t);
    expect(_wake, findsNothing);
    expect(find.text('Review activities'), findsOneWidget);
    await expectLater(find.byKey(_boundary),
        matchesGoldenFile('goldens/home_wake_card_idle.png'));
  });
}
