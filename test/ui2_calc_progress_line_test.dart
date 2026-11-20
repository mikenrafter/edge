// calcProgressLine: the live calculation line a loading screen shows as its
// detail while its data waits on derivation. Pure; null when nothing is being
// calculated.
//
// Contracts the brief leaves open:
// A known scope starts at day 1. The finished-day counter advances the
// displayed ordinal until the last day.
//  - waiting is 'Waiting to calculate sleep, recovery and strain' (no download fallback;
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
  test('deriving labels the active ordinal without the previous date', () {
    expect(
        calcProgressLine(_state('deriving',
            const SyncCalculateDetail(
                dayIndex: 3, dayTotal: 12, day: '2026-03-14'))),
        'Calculating sleep, recovery and strain · day 4 of 12');
  });

  test('deriving with counts, no day', () {
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(dayIndex: 3, dayTotal: 12))),
        'Calculating sleep, recovery and strain · day 4 of 12');
  });

  test('deriving before any count', () {
    expect(calcProgressLine(_state('deriving', const SyncCalculateDetail())),
        'Calculating sleep, recovery and strain');
    expect(calcProgressLine(_state('deriving', null)), 'Calculating sleep, recovery and strain');
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(dayIndex: 0, dayTotal: 12))),
        'Calculating sleep, recovery and strain · day 1 of 12');
  });

  test('the sync sheet caps the active ordinal at the last day', () {
    final now = DateTime(2026, 11, 19);
    for (final total in [3, 7]) {
      for (final (done, current) in [(0, 1), (1, 2), (total - 1, total), (total, total)]) {
        final state = _state('deriving', SyncCalculateDetail(dayIndex: done, dayTotal: total));
        expect(syncStatusLine(state, now),
            'Calculating sleep, recovery and strain · day $current of $total');
      }
    }
  });

  test('waiting for the lock', () {
    expect(
        calcProgressLine(_state(
            'deriving', const SyncCalculateDetail(waiting: true))),
        'Waiting to calculate sleep, recovery and strain');
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
    // WHY: the cross-day step is trends, not another daily score.
    test('cross-day calculation names trends', () {
      expect(deriveProgressLine(const DeriveProgress(crossDay: true)), 'Rebuilding trends');
    });
    test('no pass running => null', () {
      expect(deriveProgressLine(null), isNull);
    });
    test('a finished date does not label the active ordinal', () {
      expect(
          deriveProgressLine(const DeriveProgress(
              dayIndex: 3, dayTotal: 12, day: '2026-03-14')),
          'Calculating sleep, recovery and strain · day 4 of 12');
    });
    test('day count without a day', () {
      expect(
          deriveProgressLine(const DeriveProgress(dayIndex: 3, dayTotal: 12)),
          'Calculating sleep, recovery and strain · day 4 of 12');
    });
    test('a known scope starts at day 1 and an unknown scope has no ordinal', () {
      expect(
          deriveProgressLine(const DeriveProgress(dayIndex: 0, dayTotal: 12)),
          'Calculating sleep, recovery and strain · day 1 of 12');
      expect(deriveProgressLine(const DeriveProgress()), 'Calculating sleep, recovery and strain');
    });
    test('waiting', () {
      expect(deriveProgressLine(const DeriveProgress(waiting: true)),
          'Waiting to calculate sleep, recovery and strain');
    });
  });
}
