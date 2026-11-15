// Health honesty/latency pins (AGENTS.md 3.3, 4.1):
//  - Observations says "Nothing has stood out" only once the watch has run;
//    before that it says why there is nothing to say yet.
//  - A failed overview read shows the retry card, not an empty-data screen.
//  - The wearable read starts with the others (first paint waits for max()).
//  - Vitals with nothing measured keeps a "Sync the band" action in a slot
//    whose size does not depend on whether it is shown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _quiet = 'Nothing has stood out';
const _notYet = 'Starts after your first scored night';

class _App extends AppState {
  _App() : super.forTesting();
  int syncs = 0;
  @override
  Future<void> syncNow() async => syncs++;
}

class _Throws extends LocalRepository {}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester t, Widget screen, {AppState? app}) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  Widget home = Scaffold(body: screen);
  if (app != null) {
    home = ChangeNotifierProvider<AppState>.value(value: app, child: home);
  }
  await t.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.light), home: home));
  await _settle(t);
}

void main() {
  testWidgets('nothing checked yet is not "nothing stood out"', (t) async {
    await _pump(t, const HealthScreen(data: HealthData()));
    expect(find.text(_quiet), findsNothing);
    expect(find.text(_notYet), findsOneWidget);
    expect(find.byKey(const ValueKey('card:observations')), findsOneWidget);
  });

  testWidgets('the watch has run and found nothing keeps the sentence',
      (t) async {
    await _pump(
        t,
        const HealthScreen(
            data: HealthData(today: {
          'illness': {'state': 'green'}
        })));
    expect(find.text(_quiet), findsOneWidget);
    expect(find.text(_notYet), findsNothing);
    await _pump(t, const HealthScreen(data: HealthData(daysWithData: 4)));
    expect(find.text(_quiet), findsOneWidget);
  });

  testWidgets('both Observations states are the same size', (t) async {
    final key = find.byKey(const ValueKey('card:observations'));
    await _pump(t, const HealthScreen(data: HealthData()));
    final a = t.getSize(key);
    final topA = t.getTopLeft(find.byKey(const ValueKey('card:mind')));
    await _pump(t, const HealthScreen(data: HealthData(daysWithData: 4)));
    expect(t.getSize(key), a);
    expect(t.getTopLeft(find.byKey(const ValueKey('card:mind'))), topA);
  });

  testWidgets('a failed overview read shows retry, not empty data',
      (t) async {
    final app = _App();
    addTearDown(app.dispose);
    app.repo = _Throws();
    await _pump(t, const HealthScreen(), app: app);
    expect(find.text('Could not read your overview'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text(_quiet), findsNothing);
    expect(find.text(_notYet), findsNothing);
  });

  test('the wearable read starts before the others finish', () async {
    final gate = Completer<Map<String, dynamic>>();
    final repo = _Gated(gate);
    final f = HealthData.load(repo);
    await Future<void>.delayed(Duration.zero);
    expect(repo.wearableAsked, isTrue,
        reason: 'it waited for the whole load before starting');
    gate.complete(const {});
    await f.catchError((_) => const HealthData());
  });

  // CLAIM health-alert-read: alert metadata is part of the repository snapshot,
  // starts with the primary read, and returns with the same snapshot.
  // catches: a screen-level SQLite read that bypasses the repository seam.
  test('alert records start with primary and reach the matching finding', () async {
    final gate = Completer<Map<String, dynamic>>();
    final repo = _AlertRepo(gate);
    final loaded = HealthData.load(repo);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(repo.alertsAsked, isTrue,
          reason: 'alert metadata must start before the primary read finishes');
    } finally {
      gate.complete(const {});
    }
    final d = await loaded;
    expect(d.findings, hasLength(1));
    expect(d.findings.single.date, _AlertRepo.day);
    expect(d.findings.single.alert, same(repo.record));
  });

  // WHY/CLAIM(health-episode-read): episode metadata starts beside the primary
  // read and joins the same snapshot. It suppresses only its covered daily flag.
  // catches: a late screen-level SQLite read or publishing before evidence lands.
  test('episode records start with primary and join the published snapshot', () async {
    final primary = Completer<Map<String, dynamic>>();
    final episodes = Completer<List<PulseEpisodeSnapshot>>();
    final repo = _EpisodeRepo(primary, episodes);
    final episode = PulseEpisodeSnapshot({
      'id': 'strap:0', 'day': _AlertRepo.day, 'end_day': _AlertRepo.day,
    }, null);
    var published = false;
    final loaded = HealthData.load(repo).then((d) {
      published = true;
      return d;
    });
    late bool startedWithPrimary, publishedBeforeEpisodes;
    try {
      await Future<void>.delayed(Duration.zero);
      startedWithPrimary = repo.episodesAsked;
      primary.complete(const {});
      await Future<void>.delayed(Duration.zero);
      publishedBeforeEpisodes = published;
    } finally {
      if (!primary.isCompleted) primary.complete(const {});
      episodes.complete([episode]);
    }
    final d = await loaded;
    expect(startedWithPrimary, isTrue,
        reason: 'episode metadata must start before the primary read finishes');
    expect(publishedBeforeEpisodes, isFalse,
        reason: 'the overview must publish its evidence in the same snapshot');
    expect(d.pulseEpisodes, [same(episode)]);
    expect(d.pulseReadFailed, isFalse);
    expect(d.findings, isEmpty, reason: 'the episode covers the old daily flag');
  });

  // WHY/CLAIM(health-episode-read): a failed ledger read is retryable, not proof
  // there were no episodes. Other overview data and daily alert notes survive.
  test('a failed episode read retains the retry state and daily finding', () async {
    final repo = _EpisodeRepo(Completer()..complete(const {}), null);
    final d = await HealthData.load(repo);
    expect(repo.episodesAsked, isTrue);
    expect(d.pulseReadFailed, isTrue);
    expect(d.pulseEpisodes, isEmpty);
    expect(d.findings.single.date, _AlertRepo.day);
    expect(d.findings.single.alert, same(repo.record));
  });

  test('a failed wearable read is still null, not a failed load', () async {
    final repo = _Gated(Completer()..complete(const {}), wearableThrows: true);
    final d = await HealthData.load(repo);
    expect(d.wearable, isNull);
  });

  testWidgets('Vitals with nothing measured offers Sync the band', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _pump(
        t,
        const HealthScreen(
            data: HealthData(), vitals: VitalsData(), tab: 3),
        app: app);
    final rows = find.byKey(const ValueKey('card:vitals-rows'));
    final slot = find.byKey(const ValueKey('card:vitals-sync'));
    expect(find.text('Sync the band'), findsOneWidget);
    final h = t.getSize(slot).height;
    await t.tap(find.text('Sync the band'));
    expect(app.syncs, 1);
    expect(rows, findsOneWidget);

    // Same slot size when the action is not offered (no AppState).
    await _pump(
        t, const HealthScreen(data: HealthData(), vitals: VitalsData(), tab: 3));
    expect(find.text('Sync the band'), findsNothing);
    expect(t.getSize(slot).height, h);
  });
}

class _Gated extends LocalRepository {
  _Gated(this.gate, {this.wearableThrows = false});
  final Completer<Map<String, dynamic>> gate;
  final bool wearableThrows;
  bool wearableAsked = false;

  @override
  Future<Map<String, dynamic>> getTodayStored() => gate.future;
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<List<String>> availableDays() async => const [];
  @override
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to, Set<String> signals = const {}}) async => const {};
  @override
  Future<WearableDay?> wearableDay(String date) async {
    wearableAsked = true;
    if (wearableThrows) throw StateError('x');
    return null;
  }
}

class _AlertRepo extends _Gated {
  _AlertRepo(super.gate);
  static const day = '2026-11-12';
  final record = PulseAlertRecord(PulseAlertState.sent, 1794499200000);
  bool alertsAsked = false;
  @override
  Future<Map<String, dynamic>> getInsights() async => const {
    'recent': [{'date': day}],
  };
  @override
  Future<Map<String, PulseAlertRecord>> getPulseAlertRecords() async {
    alertsAsked = true;
    return {day: record};
  }
  @override
  Future<Map<String, dynamic>> getChart(String metric, {
    int? from, int? to, Set<String> signals = const {},
  }) async => metric == 'irregular_rhythm_flag'
      ? {'points': [{'t': DateTime(2026, 11, 12, 12).millisecondsSinceEpoch ~/ 1000, 'v': 1}]}
      : const {};
}

class _EpisodeRepo extends _AlertRepo {
  _EpisodeRepo(super.gate, this.episodes);
  final Completer<List<PulseEpisodeSnapshot>>? episodes;
  bool episodesAsked = false;
  @override
  Future<List<PulseEpisodeSnapshot>> getPulseEpisodes() async {
    episodesAsked = true;
    if (episodes == null) throw StateError('episode ledger unavailable');
    return episodes!.future;
  }
}
