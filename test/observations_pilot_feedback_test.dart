import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/pulse_episode.dart';
import 'package:openstrap_edge/ui2/why_row.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/skeleton_fixture.dart';

PulseEpisodeSnapshot episode(String day, {String? endDay, int minute = 0}) {
  final start =
      DateTime.parse('${day}T12:00:00Z').millisecondsSinceEpoch +
      minute * 60000;
  return PulseEpisodeSnapshot({
    'id': 'strap:$start',
    'day': day,
    'end_day': endDay ?? day,
    'start_ms': start,
    'end_ms': start + 17 * 60000,
    'alert_state': 'sent',
  }, null);
}

void main() {
  // WHY/CLAIM(observations-once): owner saw the episode above its duplicate
  // daily flag. Keep one opening per episode, without losing other detectors.
  // catches: a separate top episode list, or suppressing every kind on a day.
  testWidgets('episode replaces only its covered daily flags in day detail', (
    t,
  ) async {
    skTallView(t);
    await t.pumpWidget(
      skHost(
        FindingsLog(
          const [
            Finding(FindingKind.irregularRhythm, '2026-11-14'),
            Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
            Finding(FindingKind.irregularRhythm, '2026-11-12'),
          ],
          episodes: [episode('2026-11-13', endDay: '2026-11-14')],
          today: '2026-11-15',
        ),
      ),
    );
    await t.pump();
    expect(find.byType(PulseEpisodeRow), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChartFrame),
        matching: find.byType(PulseEpisodeRow),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-14')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-why:finding:lowReadiness:2026-11-14')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('observations-latest-week')),
      findsNothing,
    );
    final plot = t.getRect(find.byType(ChartScrub));
    // Latest week is 9–15 Nov; slot 3 is the uncovered flag on 12 Nov.
    await t.tapAt(Offset(plot.left + plot.width * 3.5 / 7, plot.center.dy));
    await t.pump();
    expect(find.byType(PulseEpisodeRow), findsNothing);
    expect(
      find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-12')),
      findsOneWidget,
    );
  });

  // WHY/CLAIM(observations-colors): phase 2's ListTile inherited a neutral
  // icon color. Both the detail and Health must retain the detector's red ink.
  // catches: relying on the theme's default leading icon color.
  testWidgets('pulse row uses the finding color', (t) async {
    await t.pumpWidget(
      skHost(
        Scaffold(body: PulseEpisodeRow(episode('2026-11-14'))),
        brightness: Brightness.dark,
      ),
    );
    final tile = t.widget<ListTile>(find.byType(ListTile));
    expect((tile.leading! as Icon).color, const P(true).on(C.red));
  });

  // WHY/CLAIM(observations-colors): daily detector colors must survive on the
  // screen and on Health, in both palettes, not just in the week markers.
  testWidgets('daily rows and Health card keep colors by finding kind', (
    t,
  ) async {
    skTallView(t);
    for (final brightness in Brightness.values) {
      final p = P(brightness == Brightness.dark);
      for (final kind in FindingKind.values) {
        final finding = Finding(kind, '2026-11-14');
        await t.pumpWidget(
          skHost(
            FindingsLog([finding], today: '2026-11-15'),
            brightness: brightness,
          ),
        );
        await t.pump(const Duration(milliseconds: 500));
        final row = find.byKey(
          ValueKey('home-why-icon:finding:${kind.name}:2026-11-14'),
        );
        expect(
          t
              .widget<Icon>(
                find.descendant(of: row, matching: find.byType(Icon)),
              )
              .color,
          p.on(findingColor(kind)),
        );
        await t.pumpWidget(
          skHost(
            Scaffold(
              body: HealthScreen(data: HealthData(findings: [finding])),
            ),
            brightness: brightness,
          ),
        );
        await t.pump();
        expect(
          t
              .widget<Icon>(
                find.descendant(
                  of: find.byType(FindingRow),
                  matching: find.byType(Icon),
                ),
              )
              .color,
          p.on(findingColor(kind)),
        );
      }
    }
  });

  // WHY/CLAIM(observations-pending): an unfinished episode read used to be
  // blank and restart on every scrub. Keep known rows and one announced label.
  // catches: an invisible FutureBuilder wait or a future created in build.
  testWidgets('pending screen shows structure and label, then fills once', (
    t,
  ) async {
    skTallView(t);
    final semantics = t.ensureSemantics();
    try {
      final gate = Completer<List<PulseEpisodeSnapshot>>();
      var reads = 0;
      await t.pumpWidget(
        skHost(
          FindingsLog(
            const [
              Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
              Finding(FindingKind.irregularRhythm, '2026-11-14'),
            ],
            today: '2026-11-15',
            loadEpisodes: () {
              reads++;
              return gate.future;
            },
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Loading observations'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('home-why:finding:irregularRhythm:2026-11-14'),
        ),
        findsNothing,
      );
      expect(
        skTraversalLabels(t).any((s) => s.contains('Loading observations')),
        isTrue,
      );
      expect(find.byType(PendingContent), findsWidgets);
      expect(find.byType(ChartFrame), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-why:finding:lowReadiness:2026-11-14')),
        findsOneWidget,
        reason: 'known findings fill before the slow read',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final plot = t.getRect(find.byType(ChartScrub));
      await t.tapAt(Offset(plot.left + plot.width * 5.5 / 7, plot.center.dy));
      await t.pump();
      expect(reads, 1);
      gate.complete([episode('2026-11-14')]);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Loading observations'), findsNothing);
      expect(find.byType(PulseEpisodeRow), findsOneWidget);
      expect(reads, 1);
    } finally {
      semantics.dispose();
    }
  });

  // WHY/CLAIM(observations-newest): any pulse episode used to displace newer
  // daily observations. Compare dates across both sources, including unsorted
  // input, and prefer an opening to a covered same-day daily flag.
  // catches: pulseEpisodes.first taking priority without comparing the day.
  testWidgets('Health card chooses the newest observation across sources', (
    t,
  ) async {
    skTallView(t);
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    addTearDown(theme.dispose);
    final older = episode('2026-11-12');
    final newer = episode('2026-11-15');
    for (final episodes in [
      [older],
      [older, newer],
    ]) {
      await t.pumpWidget(
        ChangeNotifierProvider<ThemeController>.value(
          value: theme,
          child: skHost(
            Scaffold(
              body: HealthScreen(
                key: UniqueKey(),
                data: HealthData(
                  findings: const [
                    Finding(FindingKind.tempElevated, '2026-11-14'),
                  ],
                  pulseEpisodes: episodes,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      if (episodes.length == 1) {
        expect(find.byType(FindingRow), findsOneWidget);
        expect(find.byType(PulseEpisodeRow), findsNothing);
      } else {
        expect(
          t.widget<PulseEpisodeRow>(find.byType(PulseEpisodeRow)).episode.id,
          newer.id,
        );
        expect(find.byType(FindingRow), findsNothing);
      }
      await t.tap(find.text('See all'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(
        t
            .widget<FindingsLog>(find.byType(FindingsLog))
            .episodes
            .map((e) => e.id),
        episodes.map((e) => e.id),
        reason: 'navigation reuses the loaded snapshot',
      );
      await t.pumpWidget(const SizedBox());
    }
  });

  // WHY/CLAIM(observations-newest): a live illness payload may arrive before
  // the rollup. Include its own date in ordering instead of a fixed priority.
  testWidgets(
    'current illness competes by date with episodes and daily findings',
    (t) async {
      skTallView(t);
      for (final newestDay in ['2026-11-13', '2026-11-15']) {
        await t.pumpWidget(
          skHost(
            Scaffold(
              body: HealthScreen(
                key: UniqueKey(),
                now: DateTime(2026, 11, 15),
                data: HealthData(
                  today: const {
                    'illness': {'state': 'amber', 'date': '2026-11-14'},
                  },
                  pulseEpisodes: [episode(newestDay)],
                ),
              ),
            ),
          ),
        );
        await t.pump();
        expect(
          find.byType(Observation),
          newestDay == '2026-11-13' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(PulseEpisodeRow),
          newestDay == '2026-11-15' ? findsOneWidget : findsNothing,
        );
      }
    },
  );

  // WHY/CLAIM(observations-pending): a failed metadata read must leave known
  // findings available and support an explicit retry; disposal cancels painting.
  testWidgets('episode read can fail, retry empty, and finish after disposal', (
    t,
  ) async {
    skTallView(t);
    var reads = 0;
    final gate = Completer<List<PulseEpisodeSnapshot>>();
    await t.pumpWidget(
      skHost(
        FindingsLog(
          const [Finding(FindingKind.irregularRhythm, '2026-11-14')],
          today: '2026-11-15',
          loadEpisodes: () async {
            reads++;
            if (reads == 1) throw StateError('disk unavailable');
            return gate.future;
          },
        ),
      ),
    );
    await t.pump();
    expect(find.text('Loading observations'), findsNothing);
    expect(find.byType(WhyRow), findsOneWidget);
    await t.tap(find.text('Pulse recordings could not be loaded. Try again.'));
    await t.pump();
    expect(reads, 2);
    expect(find.text('Loading observations'), findsOneWidget);
    gate.complete([]);
    await t.pump();
    expect(find.text('Loading observations'), findsNothing);
    expect(find.byType(WhyRow), findsOneWidget);
    final lateRead = Completer<List<PulseEpisodeSnapshot>>();
    await t.pumpWidget(
      skHost(
        FindingsLog(
          const [],
          key: UniqueKey(),
          loadEpisodes: () => lateRead.future,
        ),
      ),
    );
    await t.pumpWidget(const SizedBox());
    lateRead.complete([]);
    await t.pump();
    expect(t.takeException(), isNull);
  });

  // WHY/CLAIM(observations-pending): a failed read is not an empty ledger.
  // catches: showing "Nothing flagged" after the episode lookup fails.
  testWidgets('failed episode read never claims an empty observation day', (
    t,
  ) async {
    skTallView(t);
    var reads = 0;
    await t.pumpWidget(
      skHost(
        FindingsLog(
          const [],
          today: '2026-11-15',
          loadEpisodes: () async {
            if (reads++ == 0) throw StateError('unavailable');
            return [];
          },
        ),
      ),
    );
    await t.pump();
    expect(
      find.text('Pulse recordings could not be loaded. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Nothing flagged on this day.'), findsNothing);
    expect(
      t.widget<ChartKeyReadout>(find.byType(ChartKeyReadout)).cells.first.value,
      isNull,
    );
    expect(t.widget<ChartFrame>(find.byType(ChartFrame)).yAxis, isNull);
    await t.tap(find.text('Pulse recordings could not be loaded. Try again.'));
    await t.pump();
    expect(find.text('Nothing flagged on this day.'), findsOneWidget);
  });

  // WHY/CLAIM(observations-once): two different episodes on one date both
  // survive, while repeated metadata and daily rows do not add copies.
  testWidgets('distinct episodes survive repeated rows on the same day', (
    t,
  ) async {
    skTallView(t);
    final a = episode('2026-11-14'), b = episode('2026-11-14', minute: 30);
    await t.pumpWidget(
      skHost(
        FindingsLog(
          const [
            Finding(FindingKind.irregularRhythm, '2026-11-14'),
            Finding(FindingKind.tempElevated, '2026-11-14'),
            Finding(FindingKind.tempElevated, '2026-11-14'),
          ],
          episodes: [a, b, a],
          today: '2026-11-15',
        ),
      ),
    );
    expect(find.byType(PulseEpisodeRow), findsNWidgets(2));
    expect(find.byType(WhyRow), findsOneWidget);
    expect(
      t.widget<ChartKeyReadout>(find.byType(ChartKeyReadout)).cells.first.value,
      '3',
    );
  });

  // WHY/CLAIM(health-parallel-reads): chart and insight IO were serialized
  // behind today's snapshot. A blocked primary must not block their kickoff.
  // catches: awaiting today's stored read before starting other overview IO.
  test(
    'Health starts independent stored reads before the primary completes',
    () async {
      final repo = _ReadOrder();
      final loaded = HealthData.load(repo);
      await Future<void>.delayed(Duration.zero);
      final started = {...repo.started};
      repo.gate.complete(const {});
      await loaded;
      expect(
        started,
        containsAll([
          'insights',
          'profile',
          'days',
          'resting_hr',
          'hrv',
          'sleep',
          'stress',
          'resp_rate',
          'recovery',
          'irregular_rhythm_flag',
        ]),
      );
    },
  );
}

class _ReadOrder extends LocalRepository {
  final gate = Completer<Map<String, dynamic>>();
  final started = <String>{};
  @override
  Future<Map<String, dynamic>> getTodayStored() => gate.future;
  @override
  Future<Map<String, dynamic>> getInsights() async {
    started.add('insights');
    return {};
  }

  @override
  Future<Map<String, dynamic>> getProfile() async {
    started.add('profile');
    return {};
  }

  @override
  Future<List<String>> availableDays() async {
    started.add('days');
    return [];
  }

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    started.add(metric);
    return {};
  }
}
