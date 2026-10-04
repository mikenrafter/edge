// Shared harness for the 8AF Wellness link tests: the real WellnessScreen over a
// fake repository that holds a day which would have filled the OLD Recovery tab.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _day = '2026-08-16';

/// A day that would have filled the old Recovery tab: debt, a need, drivers.
class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => const {
        'status': {'today_day': _day}
      };

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async => const {
        'readiness': {'value': 62.0, 'confidence': 0.8, 'tier': 'HIGH'},
        'stress': {'score': 34},
      };

  @override
  Future<Map<String, dynamic>> getInsights() async => const {
        'readiness_glassbox': {
          'value': {
            'breakdown': [
              {
                'label': 'hrv',
                'used': true,
                'weight': 0.40,
                'weighted_contribution': -6.2,
                'past_mdc': true,
              },
            ],
          },
        },
        'sleep_debt': {
          'value': {'debt_hours': 1.4}
        },
        'sleep_coach': {
          'need': {
            'value': {'need_sec': 28800.0}
          },
          'bedtime': {
            'value': {'bedtime_min_of_day': 1380}
          },
        },
      };

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      {};

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 32));
  }
}

Future<AppState> openWellness(WidgetTester t, {String tab = 'Recovery'}) async {
  t.view.physicalSize = const Size(800 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = _Repo();
  // The screen is built ON the requested tab (`tabRequest`, read in initState)
  // rather than opened on Mind and tapped over.
  WellnessScreen.tabRequest.value = WellnessScreen.tabs.indexOf(tab);
  addTearDown(() => WellnessScreen.tabRequest.value = -1);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const Scaffold(body: WellnessScreen()),
    ),
  ));
  await settle(t);
  WellnessScreen.tabRequest.value = -1;
  return app;
}

