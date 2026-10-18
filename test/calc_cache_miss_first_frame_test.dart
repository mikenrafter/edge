// A cache-miss open never awaits a compute in a build path.
//
// With nothing stored for the screen and its read still pending (a
// Completer-gated repository), the FIRST frame is the page shell plus an
// InlineLoading in the section that waits. Never a bare spinner, never a blank
// page, and never a made-up "Updated" time: with no stored result there is no
// staleness line (§3.3; the line itself is pinned in staleness_text_test.dart
// and staleness_screen_test.dart).
//
// ASSUMED (all new behaviour is on the screens; no new API beyond
// AppState.requestWarm, see warm_request_test.dart):
//   * Home's loading state is an InlineLoading (it is a bare
//     `Center(CircularProgressIndicator())` today), under the sync line.
//     Health and Sleep detail already show one; they are pinned here so the
//     cache-first work cannot regress them.
//   * Every ProgressIndicator on a loading first frame is inside an
//     InlineLoading.
//   * Beats (an artifact screen: 'beats|<night>') on a cache MISS shows the
//     shell (title, the night header) and the section's InlineLoading, does
//     NOT run the corrected-RR read itself (repo.getNightBeats is not called by
//     the screen) and ENQUEUES the warm: AppState.requestWarm('beats|<night>'),
//     observed through app.debugArtifactSource. When the warm lands the screen
//     re-reads (revision bump), finds the stored result fresh and drops the
//     loading state; the screen still never calls getNightBeats.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/last_result_db.dart';
import 'support/artifact_fixtures.dart';
import 'support/scripted_artifact_source.dart';

const _db = 'cache_miss_first_frame_test.db';

final _bars = find.byWidgetPredicate((w) => w is ProgressIndicator,
    description: 'a ProgressIndicator');

/// Every spinner on screen sits inside an InlineLoading.
void _expectOnlyInlineLoading(String screen) {
  expect(find.byType(InlineLoading), findsWidgets,
      reason: '$screen: the section that waits says so');
  for (final e in _bars.evaluate()) {
    final inline = find
        .ancestor(
            of: find.byElementPredicate((x) => identical(x, e)),
            matching: find.byType(InlineLoading))
        .evaluate()
        .isNotEmpty;
    expect(inline, isTrue,
        reason: '$screen: a spinner outside InlineLoading is a bare spinner');
  }
}

AppState _app(LocalRepository repo) {
  final a = AppState.forTesting();
  a.repo = repo;
  addTearDown(a.dispose);
  return a;
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

class _SlowHome extends HomeRepo {
  _SlowHome() : super(homeBundle());
  final gate = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getToday() {
    reads++;
    return gate.future;
  }
}

class _SlowSleep extends SleepRepo {
  final gate = Completer<void>();
  int reads = 0;
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    reads++;
    await gate.future;
    return super.getDaySleepV2(date);
  }
}

class _SlowHealth extends HomeRepo {
  _SlowHealth() : super(homeBundle());
  final gate = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getToday() {
    reads++;
    return gate.future;
  }
}

Widget _healthApp(AppState app, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
            create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        Provider<Capabilities>.value(
            value: Capabilities(const CapabilityInputs())),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: child),
      ),
    );

/// Real-time condition wait (bounded), pumping between polls.
Future<void> _settleUntil(WidgetTester t, bool Function() ok,
    {int max = 60}) async {
  for (var i = 0; i < max && !ok(); i++) {
    await settle(t, n: 1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));
  // Writes still queued to `last_result` must land before the next test (or the
  // file's end) closes the database underneath them.
  tearDown(() => LastResultCache.instance.flush());

  Future<void> fresh(WidgetTester t) async {
    await t.runAsync(() => g1FreshDb(_db));
    LastResultCache.instance.clear();
  }

  group('first frame, read pending', () {
    testWidgets('Home: the page and an InlineLoading, no bare spinner, no '
        'staleness text', (t) async {
      _tall(t);
      await fresh(t);
      final repo = _SlowHome();
      await t.pumpWidget(perfApp(_app(repo), const HomeScreen(hour: 9)));
      await t.pump(); // post-frame: the load starts and stays pending
      expect(repo.reads, 1, reason: 'the read is in flight');

      _expectOnlyInlineLoading('Home');
      expect(find.textContaining('Updated '), findsNothing,
          reason: 'nothing stored, so no time is shown');
      expect(find.byKey(const ValueKey('as-of-label')), findsNothing);
      expect(t.takeException(), isNull);

      repo.gate.complete(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
      await settle(t);
      expect(_bars, findsNothing, reason: 'the read landed');
      expect(find.text('70'), findsOneWidget);
    });

    testWidgets('Health: the title and tabs stay, the body is an '
        'InlineLoading', (t) async {
      _tall(t);
      await fresh(t);
      final repo = _SlowHealth();
      await t.pumpWidget(_healthApp(_app(repo), const HealthScreen()));
      await t.pump();
      expect(repo.reads, 1);

      expect(find.text('Health'), findsWidgets);
      _expectOnlyInlineLoading('Health');
      expect(find.byType(InlineLoading), findsOneWidget);
      expect(find.textContaining('Updated '), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('Sleep detail: the title and an InlineLoading, no staleness '
        'text', (t) async {
      _tall(t);
      await fresh(t);
      final repo = _SlowSleep();
      await t.pumpWidget(perfApp(_app(repo), const SleepDetail()));
      await t.pump();
      await settle(t, n: 5);
      expect(repo.reads, greaterThanOrEqualTo(1));

      expect(find.text('Sleep'), findsWidgets);
      _expectOnlyInlineLoading('Sleep detail');
      expect(find.byType(InlineLoading), findsOneWidget);
      expect(find.textContaining('Updated '), findsNothing);
      expect(t.takeException(), isNull);

      repo.gate.complete();
      await settle(t);
      expect(find.byType(InlineLoading), findsNothing);
    });
  });

  group('Beats: a miss enqueues the warm', () {
    testWidgets('shell + inline loading, no inline compute, the warm is '
        'requested, and its result lands fresh', (t) async {
      _tall(t);
      await fresh(t);
      final keys = [artBeats(todayId), artBeats(yesterdayId)];
      final repo = ArtifactBeatsRepo()..beatsGate = Completer();
      for (final k in keys) {
        repo.sigs[k] = 'b1';
      }
      final value = {
        'nn': [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0],
        'raw_beats': 412,
        'clean_fraction': .97,
      };
      final src = FakeArtifactSource();
      for (final k in keys) {
        src.sigs[k] = 'b1';
        src.results[k] = value;
      }
      // The warm is held until the first frame has been checked.
      final warmGate = Completer<void>();
      for (final k in keys) {
        src.gates[k] = warmGate;
      }
      final app = _app(repo);
      app.debugArtifactSource = src;

      await t.pumpWidget(perfApp(app, const Beats()));
      // The miss is DECIDED once the screen has either run the read itself or
      // asked the warmer; wait for whichever it does (bounded, real time: the
      // store is read through sqflite_ffi), then pin which one it was.
      await _settleUntil(
          t, () => repo.beatsCalls > 0 || src.computeStarted.isNotEmpty,
          max: 120);

      expect(find.text('Beats'), findsOneWidget);
      expect(find.textContaining('Night of'), findsOneWidget,
          reason: 'the night header does not wait for the read');
      expect(find.text('Every beat against the one before it'), findsOneWidget);
      _expectOnlyInlineLoading('Beats');
      expect(repo.beatsCalls, 0,
          reason: 'the screen does not run the corrected-RR compute itself');
      expect(src.computeStarted.where((k) => k.startsWith('beats|')), hasLength(1),
          reason: 'the miss enqueued the warm for the night it shows');
      expect(find.textContaining('Updated '), findsNothing);

      warmGate.complete();
      await settle(t, n: 30);
      expect(find.byType(InlineLoading), findsNothing,
          reason: 'the warmed result was found fresh and drawn');
      expect(repo.beatsCalls, 0);
      expect(t.takeException(), isNull);
    });
  });
}
