// WHY: an ongoing durable write cannot disable sleep controls or swallow a
// newer action. The write is gated to exercise actual widget callbacks.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/theme.dart';

class _App extends AppState {
  _App() : super.forTesting();
  final receipt = Completer<SleepOperationResult>();
  int rejected = 0;
  @override
  Future<SleepOperationResult> recalculateSleep(String day) => receipt.future;
  @override
  Future<SleepOperationResult> rejectSleep(String day) async {
    rejected++;
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
}
