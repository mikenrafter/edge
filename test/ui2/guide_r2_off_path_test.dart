import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

bool _selected(WidgetTester t, int i) => t.widgetList<Semantics>(find.descendant(
  of: r2Tab(i), matching: find.byType(Semantics))).any((w) => w.properties.selected == true);

void main() {
  setUpAll(() => r2OpenDb('guide_r2_off_path.db'));
  tearDownAll(LocalDb.close);

  // WHY: off-path dims include icon backgrounds, not only tab text, while
  // precisely one return tab remains full colour. Exercise the shipped runner.
  // # catches: globally exempting the tab bar, dimming just each icon/text,
  // or turning off all painting when currentStep is null.
  testWidgets('r2 off-path shell dims every component except the route-back tab', (t) async {
    final app = await pumpLiveGuideApp(t, size: r2Size);
    try {
      final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
      await settleLiveGuide(t, frames: 18);
      await t.tapAt(t.getRect(r2Tab(3)).center);
      await settleLiveGuide(t, frames: 12);
      expect(started.run.state, isA<GuideOffPath>());
      expect(_selected(t, 3), isTrue);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      final back = t.getRect(r2Tab(0));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(back)), isEmpty,
        reason: 'Today is the one route back');
      for (var i = 1; i < 4; i++) {
        final rect = t.getRect(r2Tab(i));
        expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, rect)), isTrue,
          reason: 'tab $i: whole box, including selected Health pigment');
      }
      final page = app.runner.routes.page!;
      for (final unit in r2Units(page)) {
        expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, unit.rect)), isTrue,
          reason: 'off-path component ${unit.element.widget.runtimeType}: ${unit.text}');
      }
      final button = t.getRect(find.byKey(GuideStepCard.backToGuideKey));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(button)), isEmpty);
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });

  // WHY: amendment A/C keeps every dimmed tab interactive; the return tab
  // alone stays full colour, and can still bring the guide back.
  // # catches: absorbing dimmed off-path tabs or blocking the return tab.
  testWidgets('r2 off-path shell keeps dimmed tabs and return tab interactive', (t) async {
    final app = await pumpLiveGuideApp(t, size: r2Size);
    try {
      final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
      await settleLiveGuide(t, frames: 18);
      await t.tapAt(t.getRect(r2Tab(3)).center);
      await settleLiveGuide(t, frames: 12);
      expect(started.run.state, isA<GuideOffPath>());
      await t.tapAt(t.getRect(r2Tab(2)).center);
      await settleLiveGuide(t);
      expect(_selected(t, 2), isTrue, reason: 'dimmed Activity tab performs its normal navigation');
      await t.tapAt(t.getRect(r2Tab(0)).center);
      await settleLiveGuide(t, frames: 12);
      expect(_selected(t, 0), isTrue);
      expect(started.run.currentStep?.id, 'open-strain');
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });
}
