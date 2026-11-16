// WHY/CLAIM(observations-pilot-renders): inspect the actual dark Flutter
// layouts requested by the owner, with real text and icon fonts.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart';

PulseEpisodeSnapshot _episode(String day) => PulseEpisodeSnapshot({
  'id': 'strap:$day',
  'day': day,
  'end_day': day,
  'start_ms': DateTime.parse('${day}T12:00:00Z').millisecondsSinceEpoch,
  'end_ms': DateTime.parse('${day}T12:17:00Z').millisecondsSinceEpoch,
  'alert_state': 'sent',
  'alert_reason': 'before this version',
}, null);

void main() {
  setUpAll(skLoadAppFonts);
  testWidgets('dark Observations loading, loaded and newest Health cards', (
    t,
  ) async {
    skTallView(t, w: 390, h: 900);
    final gate = Completer<List<PulseEpisodeSnapshot>>();
    await t.pumpWidget(
      pilotShot(
        skHost(
          FindingsLog(
            const [
              Finding(FindingKind.irregularRhythm, '2026-11-14'),
              Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
              Finding(FindingKind.tempElevated, '2026-11-12'),
            ],
            today: '2026-11-15',
            loadEpisodes: () => gate.future,
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 250));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Loading observations'), findsOneWidget);
    await takePilotShot(t, 'observations-loading-dark');
    gate.complete([_episode('2026-11-14')]);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('observations-latest-week')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-14')),
      findsNothing,
    );
    // Also inspect a fresh open using Health's already-loaded snapshot.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      pilotShot(
        skHost(
          FindingsLog(
            const [
              Finding(FindingKind.irregularRhythm, '2026-11-14'),
              Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
              Finding(FindingKind.tempElevated, '2026-11-12'),
            ],
            today: '2026-11-15',
            episodes: [_episode('2026-11-14')],
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await takePilotShot(t, 'observations-loaded-dark');
    expect(t.takeException(), isNull);

    for (final pulseIsNewest in [false, true]) {
      await t.pumpWidget(
        pilotShot(
          skHost(
            Scaffold(
              body: HealthScreen(
                key: ValueKey(pulseIsNewest),
                data: HealthData(
                  findings: [
                    Finding(
                      FindingKind.tempElevated,
                      pulseIsNewest ? '2026-11-14' : '2026-11-15',
                    ),
                  ],
                  pulseEpisodes: [
                    _episode(pulseIsNewest ? '2026-11-15' : '2026-11-14'),
                  ],
                ),
              ),
            ),
            brightness: Brightness.dark,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      await t.ensureVisible(find.byKey(const ValueKey('card:observations')));
      await t.pump(const Duration(milliseconds: 500));
      await takePilotShot(
        t,
        pulseIsNewest
            ? 'health-newest-episode-dark'
            : 'health-newest-daily-dark',
      );
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
  });
}
