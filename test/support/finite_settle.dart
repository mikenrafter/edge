import 'package:flutter_test/flutter_test.dart';

/// Pumps a fixed stretch of fake time instead of `pumpAndSettle`.
///
/// `pumpAndSettle` waits for the frame queue to empty, and it never does while a
/// pending-section placeholder pulses (d3c53c24c, 2026-11-14) or a guide card's
/// hand/pulse loop runs (the guide pulse). Those animations are meant to run
/// until the read lands or the guide ends, so a test that does not need the end
/// state pumps a bounded time.
Future<void> settleFinite(WidgetTester t,
    {int frames = 12, Duration step = const Duration(milliseconds: 100)}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(step);
  }
}
