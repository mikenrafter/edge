// why: retained health advice must stay qualified through a failed read, and a
// successful absent result must replace it. CLAIM(home-cache-freshness).
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'support/as_of_recalc_fakes.dart';

class _Reads extends HomeRepo {
  _Reads() : super(homeBundle(withDaily: false));
  var next = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getTodayStored() => next.future;
}

void main() {
  testWidgets(
    'cold restored judgments stay dated after failure, then fresh absence clears them',
    (t) async {
      ClockFormatController.seed(ClockFormat.h24);
      addTearDown(ClockFormatController.debugReset);
      final day = todayLabel();
      // Literal persisted fixture, independent of the writer under test.
      final read = DateTime(2026, 11, 12, 8, 14);
      final computed = DateTime(2026, 11, 12, 6, 30);
      SharedPreferences.setMockInitialValues({
        HomeRingDetailCache.prefKey: jsonEncode({
          'local-profile:$day:en_US': {
            'readAt': read.millisecondsSinceEpoch,
            'overnightAt': computed.millisecondsSinceEpoch,
            'activityAt': computed.millisecondsSinceEpoch,
            'readiness': {'value': 22, 'confidence': 1.0},
            'sleep': {'value': 300, 'confidence': 1.0},
            'need': {'value': 480, 'confidence': 1.0},
            'strain': {'value': 14, 'confidence': 1.0},
          },
        }),
      });
      await Prefs.ensureLoaded();
      final repo = _Reads();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(perfApp(app, const HomeScreen()));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
      expect(find.text('Last known Thu, Nov 12 08:14 · updating'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Read .*08:14.*Calculated .*06:30')),
        findsWidgets,
      );
      final before = t
          .getTopLeft(find.byKey(const ValueKey('home-ring-details')))
          .dy;
      repo.next.completeError(StateError('read failed'));
      await t.pump();
      await t.pump();
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
      expect(
        find.text('Last known Thu, Nov 12 08:14 · update failed'),
        findsOneWidget,
      );
      // The ring template shrinks on failure, while the following cached rows
      // must move through the boundary's animation instead of jumping.
      expect(
        t.getTopLeft(find.byKey(const ValueKey('home-ring-details'))).dy,
        before,
      );
      await t.pump(const Duration(milliseconds: 80));
      final middle = t
          .getTopLeft(find.byKey(const ValueKey('home-ring-details')))
          .dy;
      await t.pump(const Duration(milliseconds: 170));
      final end = t
          .getTopLeft(find.byKey(const ValueKey('home-ring-details')))
          .dy;
      if (end != before) {
        expect(
          middle,
          inExclusiveRange(
            before < end ? before : end,
            before < end ? end : before,
          ),
        );
      }
      repo.next = Completer<Map<String, dynamic>>();
      app.insightsRevision.value++;
      await t.pump();
      expect(find.textContaining('Last known'), findsOneWidget);
      repo.next.complete(homeBundle(withDaily: false));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('Last known'), findsNothing);
      expect(find.text('Recovery 22 of 100'), findsNothing);
      expect(
        HomeRingDetailCache.local.read(day, 'en_US')!.data.readiness.value,
        isNull,
      );
      semantics.dispose();
      await t.pumpWidget(const SizedBox());
    },
  );
}
