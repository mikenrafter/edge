// 8AM (red): the Home community cards (Join Discord / Support OpenStrap) and
// the 8AK gesture-failure card must stay dismissed through a burst of
// insightsRevision bumps, a reload in flight, and a Home list that changes
// shape while a big recalculation publishes day by day.
//
// USER: "the sponsor/discord home page cards are getting stuck. Dismissing
// them seems to do nothing. Seems to coincide with large recalculations."

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/nudges.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../perf/support/perf_fakes.dart';

/// A repo whose `getToday` can be held open, to keep a reload in flight.
class _GatedRepo extends HomeRepo {
  _GatedRepo(super.today);
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> getToday() async {
    final g = gate;
    if (g != null) await g.future;
    return super.getToday();
  }
}

final _discordTitle = find.text('OpenStrap Discord');
final _donateTitle = find.text('Support OpenStrap');
final _dontShow = find.text("Don't show this again");
final _notNow = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == 'Not now');
const _failureCard = ValueKey('gesture-failure-card');

Future<void> _boot(WidgetTester t, {bool dev = false, Map<String, Object>? seed}) async {
  await t.runAsync(() async {
    // Prefs keeps the first instance for the process; reseed that one in
    // place (a second setMockInitialValues would hand out a different one).
    await Prefs.ensureLoaded();
    final sp = await SharedPreferences.getInstance();
    await sp.clear();
    for (final e in {if (dev) 'dev.mode': true, ...?seed}.entries) {
      await sp.setBool(e.key, e.value as bool);
    }
    CommunityNudge.debugResetSession();
  });
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 3200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _burst(WidgetTester t, AppState app, _GatedRepo repo, int n) async {
  for (var i = 0; i < n; i++) {
    // Alternate a full day and a bare one: the Home list changes shape the
    // way it does while a recalculation republishes a day.
    repo.today = homeBundle(withDaily: i.isOdd, readiness: 60 + i);
    app.bumpInsights();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 16));
  }
  await settle(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  Future<(AppState, _GatedRepo)> pumpHome(WidgetTester t) async {
    final repo = _GatedRepo(homeBundle());
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settle(t);
    return (app, repo);
  }

  group('community cards', () {
    testWidgets('both show on a fresh install', (t) async {
      _tall(t);
      await _boot(t);
      await pumpHome(t);
      expect(_discordTitle, findsOneWidget);
      expect(_donateTitle, findsOneWidget);
    });

    testWidgets('Not now hides a card at once and it stays hidden through a '
        'burst of revision bumps', (t) async {
      _tall(t);
      await _boot(t);
      final (app, repo) = await pumpHome(t);
      await t.tap(_notNow.first);
      await t.pump();
      expect(_discordTitle, findsNothing);
      await _burst(t, app, repo, 12);
      expect(_discordTitle, findsNothing, reason: 'a reload brought it back');
    });

    testWidgets("Don't show again survives the burst and a restart",
        (t) async {
      _tall(t);
      await _boot(t);
      final (app, repo) = await pumpHome(t);
      await t.tap(_dontShow.first);
      await t.pump();
      expect(_discordTitle, findsNothing);
      await _burst(t, app, repo, 12);
      expect(_discordTitle, findsNothing);
      expect(Prefs.getBool('nudge.discord.dismissed', false), isTrue);

      await t.pumpWidget(const SizedBox());
      await _boot(t, seed: {'nudge.discord.dismissed': true});
      await pumpHome(t);
      expect(_discordTitle, findsNothing);
    });

    testWidgets('a dismissal tapped while a reload is in flight sticks when '
        'that reload lands', (t) async {
      _tall(t);
      await _boot(t);
      final (app, repo) = await pumpHome(t);
      repo.gate = Completer<void>();
      app.bumpInsights();
      await t.pump();
      await t.tap(_dontShow.first);
      await t.pump();
      expect(_discordTitle, findsNothing);
      repo.gate!.complete();
      repo.gate = null;
      await settle(t);
      expect(_discordTitle, findsNothing);
    });

    testWidgets('developer mode: a dismissal still hides the card for the '
        'session, through the burst', (t) async {
      _tall(t);
      await _boot(t, dev: true);
      final (app, repo) = await pumpHome(t);
      expect(_discordTitle, findsOneWidget);
      await t.tap(_dontShow.first);
      await t.pump();
      expect(_discordTitle, findsNothing, reason: 'the tap did nothing');
      await _burst(t, app, repo, 12);
      expect(_discordTitle, findsNothing, reason: 'a remount brought it back');
    });

    testWidgets('developer mode: a fresh launch shows the cards again, so '
        'they stay testable', (t) async {
      _tall(t);
      await _boot(t, dev: true);
      await pumpHome(t);
      await t.tap(_dontShow.first);
      await t.pump();
      await t.pumpWidget(const SizedBox());
      await _boot(t, dev: true); // a new process
      await pumpHome(t);
      expect(_discordTitle, findsOneWidget);
    });
  });

  group('gesture failure card', () {
    Future<(AppState, _GatedRepo)> withFailure(WidgetTester t) async {
      final repo = _GatedRepo(homeBundle());
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.runAsync(() => app.gestureFailures.record(
          kind: GestureFailureKind.ecg,
          reason: 'start_failed',
          gestureId: 'g1',
          log: 'log'));
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      return (app, repo);
    }

    testWidgets('Dismiss removes it and it stays gone through the burst, '
        'then after a restart', (t) async {
      _tall(t);
      await _boot(t);
      final (app, repo) = await withFailure(t);
      expect(find.byKey(_failureCard), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gesture-failure-dismiss')));
      await t.pump();
      expect(find.byKey(_failureCard), findsNothing);
      await _burst(t, app, repo, 12);
      expect(find.byKey(_failureCard), findsNothing);
      expect(app.gestureFailures.newestUndismissed, isNull);

      await t.pumpWidget(const SizedBox());
      final restarted = GestureFailureStore(
          read: () => Prefs.getString(Prefs.gestureFailures, ''));
      expect(restarted.newestUndismissed, isNull,
          reason: 'the dismissal reached storage');
    });

    testWidgets('a dismissal tapped mid-reload sticks', (t) async {
      _tall(t);
      await _boot(t);
      final (app, repo) = await withFailure(t);
      repo.gate = Completer<void>();
      app.bumpInsights();
      await t.pump();
      await t.tap(find.byKey(const ValueKey('gesture-failure-dismiss')));
      await t.pump();
      repo.gate!.complete();
      repo.gate = null;
      await settle(t);
      expect(find.byKey(_failureCard), findsNothing);
    });
  });
}
