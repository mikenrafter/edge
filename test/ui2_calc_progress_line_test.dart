// calcProgressLine: the live calculation line a loading screen shows as its
// detail while its data waits on derivation. Pure; null when nothing is being
// calculated.
//
// Contracts the brief leaves open:
//  - dayIndex 0 with a known total reads 'Calculating…', the same rule as
//    syncStatusLine (a count appears once a day has finished).
//  - waiting is 'Waiting for another calculation' (no download fallback;
//    that belongs to the sync sheet's sentence, not a screen's detail).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/sync_control.dart';

SyncPresentationState _state(String phase, SyncCalculateDetail? calc) =>
    SyncPresentationState(
      phase: phase,
      busy: phase == 'deriving',
      steps: [
        const SyncStep(id: SyncStepId.connect, status: SyncStepStatus.done),
        const SyncStep(id: SyncStepId.download, status: SyncStepStatus.done),
        SyncStep(
            id: SyncStepId.calculate,
            status: SyncStepStatus.running,
            calculate: calc),
        const SyncStep(id: SyncStepId.done),
      ],
    );

void main() {
  test('deriving with counts and the day', () {
    expect(
        calcProgressLine(_state('deriving',
            const SyncCalculateDetail(
                dayIndex: 3, dayTotal: 12, day: '2026-03-14'))),
        'Calculating · day 3 of 12 · 2026-03-14');
  });

  test('deriving with counts, no day', () {
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(dayIndex: 3, dayTotal: 12))),
        'Calculating · day 3 of 12');
  });

  test('deriving before any count', () {
    expect(calcProgressLine(_state('deriving', const SyncCalculateDetail())),
        'Calculating…');
    expect(calcProgressLine(_state('deriving', null)), 'Calculating…');
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(dayIndex: 0, dayTotal: 12))),
        'Calculating…');
  });

  test('waiting for the lock', () {
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(waiting: true))),
        'Waiting for another calculation');
  });

  test('not deriving => null', () {
    for (final phase in [
      'connecting',
      'downloading',
      'completed',
      'failed',
      'offline',
      'idle',
    ]) {
      expect(
          calcProgressLine(_state(phase,
              const SyncCalculateDetail(dayIndex: 3, dayTotal: 12))),
          isNull,
          reason: phase);
    }
  });

  // deriveProgressLine: the same line from AppState.deriveProgress, which every
  // derive pass feeds (sync or not), so a post-import pass shows too.
  group('deriveProgressLine', () {
    test('no pass running => null', () {
      expect(deriveProgressLine(null), isNull);
    });
    test('day count with the last finished day', () {
      expect(
          deriveProgressLine(const DeriveProgress(
              dayIndex: 3, dayTotal: 12, day: '2026-03-14')),
          'Calculating · day 3 of 12 · 2026-03-14');
    });
    test('day count without a day', () {
      expect(
          deriveProgressLine(const DeriveProgress(dayIndex: 3, dayTotal: 12)),
          'Calculating · day 3 of 12');
    });
    test('no finished day yet, or no count => Calculating…', () {
      expect(
          deriveProgressLine(const DeriveProgress(dayIndex: 0, dayTotal: 12)),
          'Calculating…');
      expect(deriveProgressLine(const DeriveProgress()), 'Calculating…');
    });
    test('waiting', () {
      expect(deriveProgressLine(const DeriveProgress(waiting: true)),
          'Waiting for another calculation');
    });
  });
}
