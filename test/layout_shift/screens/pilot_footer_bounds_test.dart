// WHY: reserving the legacy editor's footer must not consume a short screen.
// A large-text landscape viewport must retain a scrollable content area.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

void main() {
  setUpAll(skLoadAppFonts);
  testWidgets('legacy footer fits landscape with large text', (t) async {
    t.view.physicalSize = const Size(640, 360);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, Builder(builder: (c) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(3.1)),
      child: const MomentReviewEditor(preloaded: [], preloadedAssumed: []))),
      brightness: Brightness.dark));
    await t.pump();
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
