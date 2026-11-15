// WHY: the embedded Sleep tab must expose durable edits just like the pushed
// screen. Loading through SleepData proves status is not lost at the read seam.
// CLAIM(sleep-edit-tab); catches: _tabBody bypassing _answerSlot, status dropped
// by SleepData.load, or already-applied values pulsing during dependent work.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'support/as_of_recalc_fakes.dart';

class _SleepRepo extends SleepRepo {
  _SleepRepo(this.phase);
  final String phase;
  @override
  Future<List<String>> availableDays() async => ['2026-11-13'];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
    'has_sleep': true,
    'duration_min': 420,
    'in_bed_min': 480,
    'sleep_source': 'manual',
    'onset_ts': 1794524400,
    'wake_ts': 1794553200,
    'recalculating': phase != 'failed',
    'calculation_error': phase == 'failed'
        ? 'Later days could not be recalculated.'
        : null,
    'dependent_recalculation': phase == 'dependents',
    'sleep_edit': SleepEditView(
      ownPhase: phase,
      ownUnapplied: phase != 'dependents',
    ),
  };
}

void main() {
  for (final phase in ['queued', 'dependents', 'failed']) {
    testWidgets('R3 embedded Sleep tab exposes $phase edits after loading', (
      t,
    ) async {
      t.view.physicalSize = const Size(1200, 22000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final repo = _SleepRepo(phase);
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final data = await SleepData.load(repo, want: '2026-11-13');
      expect((data.night['sleep_edit'] as SleepEditView).ownPhase, phase);
      expect(data.night['recalculating'], phase != 'failed');
      expect(data.night['dependent_recalculation'], phase == 'dependents');
      expect(
        data.night['calculation_error'],
        phase == 'failed' ? 'Later days could not be recalculated.' : null,
      );
      await t.pumpWidget(perfApp(app, SleepDetail(embedded: true, data: data)));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('sleep-tab:timeline')), findsOneWidget);
      final answer = find.byKey(const ValueKey('card:answer'));
      final pendingAnswer = find.ancestor(
        of: answer,
        matching: find.byWidgetPredicate(
          (w) => w is PendingContent && w.pending,
        ),
      );
      if (phase == 'queued') {
        expect(find.text('Recalculating this night'), findsOneWidget);
        expect(pendingAnswer, findsOneWidget);
      } else if (phase == 'dependents') {
        expect(find.text('Updating later days'), findsOneWidget);
        expect(pendingAnswer, findsNothing);
        expect(
          find.descendant(of: answer, matching: find.text('7h 00m')),
          findsOneWidget,
        );
      } else {
        expect(
          find.text('Later days could not be recalculated.'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
        expect(pendingAnswer, findsNothing);
      }
      await t.pumpWidget(const SizedBox());
    });
  }
}
