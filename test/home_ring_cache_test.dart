// CLAIM home-ring-cache: an already-read day's detail rows survive a cold
// pending read; the rings themselves remain pending until that read settles.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'support/as_of_recalc_fakes.dart';

class _HeldHome extends HomeRepo {
  _HeldHome() : super(homeBundle(readiness: 30));
  final gate = Completer<void>();
  @override
  Future<Map<String, dynamic>> getTodayStored() async {
    await gate.future;
    return today;
  }
}

void main() {
  test(
    'detail snapshots are durable, bounded and isolated by day and user',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      var user = 'cache-a';
      final cache = HomeRingDetailCache(userKey: () => user, limit: 2);
      final computed = DateTime.utc(2026, 11, 12, 6, 30);
      final d = HomeData(
        overnightAt: computed,
        activityAt: computed,
        readiness: Metric(
          value: 23,
          confidence: .8,
          fromOlderVersion: 12,
          olderVersionReason: 'Earlier method',
        ),
      );
      cache.record('2026-11-12', 'en', d, null);
      expect(cache.read('2026-11-13', 'en'), isNull);
      user = 'cache-b';
      expect(cache.read('2026-11-12', 'en'), isNull);
      user = 'cache-a';
      await Future<void>.value();
      await SettingsRepository.instance.update((_) {}, sections: const {});
      final restored = HomeRingDetailCache(userKey: () => user, limit: 2);
      final metric = restored.read('2026-11-12', 'en')!.data.readiness;
      // why: restored judgments must retain their source times, not gain 'now'.
      // CLAIM(home-cache-freshness); catches dropping source metadata on encode.
      expect(restored.read('2026-11-12', 'en')!.data.overnightAt, computed);
      expect(restored.read('2026-11-12', 'en')!.data.activityAt, computed);
      final encoded =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  HomeRingDetailCache.prefKey,
                )!,
              )
              as Map;
      expect((encoded.values.first as Map)['readAt'], isA<int>());
      expect(metric.value, 23);
      expect(metric.confidence, .8);
      expect(metric.fromOlderVersion, 12);
      expect(metric.olderVersionReason, 'Earlier method');
      expect(prefsKeyBackedUp(HomeRingDetailCache.prefKey), isFalse);
      restored.record('2026-11-13', 'en', d, null);
      restored.record('2026-11-14', 'en', d, null);
      expect(restored.read('2026-11-12', 'en'), isNull);
    },
  );
  testWidgets(
    'last known ring details paint before a cold read and update in place',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      final repo = _HeldHome();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(
        perfApp(
          app,
          HomeScreen(
            data: HomeData(
              dayId: todayLabel(),
              readiness: const Metric(value: 22, confidence: 1),
              strain: const Metric(value: 14, confidence: 1),
              sleepMin: const Metric(value: 300, confidence: 1),
              sleepNeedMin: const Metric(value: 480, confidence: 1),
            ),
          ),
        ),
      );
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
      final settledRows = t.getRect(
        find.byKey(const ValueKey('home-ring-details')),
      );
      await t.pumpWidget(const SizedBox());
      await t.runAsync(
        () => SettingsRepository.instance.update((_) {}, sections: const {}),
      );
      await t.pumpWidget(perfApp(app, const HomeScreen()));
      expect(
        find.text('Recovery 22 of 100'),
        findsOneWidget,
        reason:
            'the same-day secondary cache must be readable before first paint',
      );
      expect(
        t.getRect(find.byKey(const ValueKey('home-ring-details'))),
        settledRows,
        reason: 'cached text and the ring sizing template retain row geometry',
      );
      // why: readable retained health advice must be visibly and accessibly stale.
      // CLAIM(home-cache-freshness); catches retaining the values with no qualifier.
      expect(find.textContaining('Last known'), findsOneWidget);
      expect(find.textContaining('updating'), findsOneWidget);
      final semantics = t.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp('Last known.*updating')),
        findsWidgets,
      );
      semantics.dispose();
      final rows = find.text('Recovery 22 of 100');
      expect(
        find.ancestor(
          of: rows,
          matching: find.byWidgetPredicate(
            (w) => w is PendingContent && w.pending,
          ),
        ),
        findsNothing,
      );
      repo.gate.complete();
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Recovery 30 of 100'), findsOneWidget);
      expect(find.text('Recovery 22 of 100'), findsNothing);
      expect(find.textContaining('Last known'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
}
