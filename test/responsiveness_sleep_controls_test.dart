// WHY: an ongoing durable write cannot disable sleep controls or swallow a
// newer action. The write is gated to exercise actual widget callbacks.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/theme.dart';

class _App extends AppState {
  _App() : super.forTesting();
  final receipt = Completer<SleepOperationResult>();
  int rejected = 0, recalculated = 0, cleared = 0;
  Completer<SleepOperationResult>? slowReject;
  @override
  Future<SleepOperationResult> clearSleepOverride(String day) async {
    cleared++;
    return const SleepOperationResult(success: true, recalculating: true);
  }
  @override
  Future<SleepOperationResult> recalculateSleep(String day) {
    recalculated++;
    return receipt.future;
  }
  @override
  Future<SleepOperationResult> rejectSleep(String day) async {
    rejected++;
    if (slowReject != null) return slowReject!.future;
    return const SleepOperationResult(success: true, recalculating: true);
  }
}

void main() {
  testWidgets('sleep actions stay enabled while a receipt is pending', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = _App();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const SleepDetail(
            data: SleepData(
              day: '2026-11-13',
              night: {
                'has_sleep': false,
                'sleep_source': 'manual',
                'onset_ts': 1000,
                'wake_ts': 4600,
              },
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final recalculate = find.widgetWithText(
      TextButton,
      'Recalculate this night',
    );
    await t.ensureVisible(recalculate);
    await t.tap(recalculate);
    await t.pump();
    for (final label in [
      'Change the times',
      'Back to automatic',
      'Not sleep',
    ]) {
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, label)).onPressed,
        isNotNull,
        reason: label,
      );
    }
    final reject = find.widgetWithText(TextButton, 'Not sleep');
    await t.ensureVisible(reject);
    await t.tap(reject);
    await t.pump();
    expect(app.rejected, 1);
    app.receipt.complete(
      const SleepOperationResult(success: true, recalculating: true),
    );
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  Future<_App> pump(WidgetTester t, Map<String, dynamic> night, {_App? app}) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final a = app ?? _App();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: a,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: SleepDetail(data: SleepData(day: '2026-11-13', night: night))),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    return a;
  }

  const saved = {'has_sleep': false, 'sleep_source': 'manual', 'onset_ts': 1000, 'wake_ts': 4600};

  // F6: a job that failed is not "recalculating": no placeholder pulse, an
  // error that can be read, and a Retry that runs the night again.
  testWidgets('a failed recalculation reads as failed and offers Retry', (t) async {
    final app = await pump(t, {...saved, 'recalculating': false,
        'calculation_error': 'Recalculation failed. Your times are saved. Retry.'});
    expect(find.textContaining('Recalculation failed'), findsOneWidget);
    expect(find.text('Recalculating this night'), findsNothing,
        reason: 'it is not running, so it must not claim to be');
    expect(find.byWidgetPredicate((w) => w is PendingContent && w.pending), findsNothing,
        reason: 'no pulse for work that is not running');
    final retry = find.widgetWithText(TextButton, 'Retry');
    expect(retry, findsOneWidget);
    await t.ensureVisible(retry);
    await t.tap(retry);
    await t.pump();
    expect(app.recalculated, 1);
    app.receipt.complete(const SleepOperationResult(success: true, recalculating: true));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // F6: while it really runs, the explanation is announced and readable.
  testWidgets('a running recalculation keeps its explanation readable and announced', (t) async {
    final handle = t.ensureSemantics();
    final app = await pump(t, {...saved, 'recalculating': true});
    expect(find.text('Recalculating this night'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Recalculating this night')), findsWidgets,
        reason: 'PendingContent must not hide the status text from semantics');
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    await t.pumpWidget(const SizedBox());
    handle.dispose();
    app.dispose();
  });

  // F4: one answer slot for every entry to the screen.
  testWidgets('the answer slot shows the failure and the saving line for a night with numbers too', (t) async {
    final app = await pump(t, {'has_sleep': true, 'duration_min': 420,
        'sleep_source': 'manual', 'onset_ts': 1000, 'wake_ts': 4600,
        'calculation_error': 'Recalculation failed. Your times are saved. Retry.'});
    expect(find.textContaining('Recalculation failed'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // F9: a failed save is never dropped because the user did something else.
  testWidgets('a failed save is shown even after the user acted again', (t) async {
    final app = _App()..slowReject = Completer<SleepOperationResult>();
    await pump(t, saved, app: app);
    final reject = find.widgetWithText(TextButton, 'Not sleep');
    await t.ensureVisible(reject);
    await t.tap(reject);
    await t.pump();
    final auto = find.widgetWithText(TextButton, 'Back to automatic');
    await t.ensureVisible(auto);
    await t.tap(auto); // a newer action while the first is still in flight
    await t.pump();
    expect(app.cleared, 1);
    app.slowReject!.complete(const SleepOperationResult(success: false, error: 'disk full'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('disk full'), findsWidgets,
        reason: 'the first save failed; the user must be told');
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
}
