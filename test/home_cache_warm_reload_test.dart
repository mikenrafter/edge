// why: retained health advice must stay qualified through a failed read, and a
// successful absent result must replace it. CLAIM(home-cache-freshness).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'support/as_of_recalc_fakes.dart';

class _Reads extends HomeRepo {
  _Reads() : super(homeBundle(withDaily: false));
  var next = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getTodayStored() => next.future;
}

void main() {
  // why: revisions can correct advice after a successful read; retained advice
  // must be dated during every pending read. CLAIM(home-cache-freshness).
  testWidgets(
    'warm reload qualifies success, failure, retry and fresh absence',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      final repo = _Reads();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, const HomeScreen()));
      repo.next.complete(homeBundle(readiness: 22));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
      expect(find.textContaining('Last known'), findsNothing);
      final saved = HomeRingDetailCache.local
          .read(todayLabel(), 'en_US')!
          .readAt;
      repo.next = Completer<Map<String, dynamic>>();
      app.insightsRevision.value++;
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
      expect(find.textContaining('Last known'), findsOneWidget);
      expect(
        HomeRingDetailCache.local.read(todayLabel(), 'en_US')!.readAt,
        saved,
      );
      repo.next.completeError(StateError('warm failure'));
      await t.pump();
      await t.pump();
      expect(find.textContaining('update failed'), findsOneWidget);
      repo.next = Completer<Map<String, dynamic>>();
      app.insightsRevision.value++;
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('updating'), findsOneWidget);
      repo.next.complete(homeBundle(readiness: 30));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Recovery 30 of 100'), findsOneWidget);
      expect(find.textContaining('Last known'), findsNothing);
      repo.next = Completer<Map<String, dynamic>>();
      app.insightsRevision.value++;
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Last known'), findsOneWidget);
      repo.next.complete(homeBundle(withDaily: false));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('Last known'), findsNothing);
      expect(find.text('Recovery 30 of 100'), findsNothing);
      expect(
        HomeRingDetailCache.local
            .read(todayLabel(), 'en_US')!
            .data
            .readiness
            .value,
        isNull,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
}
