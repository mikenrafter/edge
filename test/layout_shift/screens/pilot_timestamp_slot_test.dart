// WHY: reserving a physical 24 px timestamp clipped large-text freshness copy.
// The reserved slot must let its actual text lay out at the wearer's scale.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

void main() {
  setUpAll(skLoadAppFonts);
  testWidgets('Sleep timestamp keeps its scaled line height', (t) async {
    phoneSurface(t);
    final now = DateTime.now();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugSetRecalc(RecalcState(days: {todayId}, passStartedAt: now));
    final data = SleepData(day: todayId, night: {
      'duration_min': 400,
      'onset_ts': now.millisecondsSinceEpoch ~/ 1000 - 30000,
      'wake_ts': now.millisecondsSinceEpoch ~/ 1000 - 6000,
      'computed_at': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    await t.pumpWidget(perfApp(app, Builder(builder: (c) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(3.1)),
      child: SleepDetail(data: data)))));
    await t.pump();
    final label = find.byKey(const ValueKey('as-of-label'));
    expect(label, findsOneWidget);
    final paragraph = t.renderObject<RenderParagraph>(label);
    expect(paragraph.size.height,
      greaterThanOrEqualTo(paragraph.getMinIntrinsicHeight(paragraph.size.width)),
      reason: 'the timestamp must keep its scaled text, without clipping it into 24 px');
    await t.pumpWidget(const SizedBox());
  });
}
