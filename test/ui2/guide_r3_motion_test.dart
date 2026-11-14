import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide_motion.dart';

void main() {
  // WHY: every painter uses the same phase; value alone changes, by exactly 8%.
  // proves: CLAIM(guide-pulse).
  // # catches: constant placeholders, half-duration cycles and linear ramps.
  test('F: pulse has a 1.6s cycle, +/-8 percent and ease-in-out extrema', () {
    expect(kGuidePulseDuration.inMilliseconds, 1600);
    expect(guidePulseValue(0), closeTo(.92, .0001));
    expect(guidePulseValue(.5), closeTo(1.08, .0001));
    expect(guidePulseValue(1), closeTo(.92, .0001));
    expect(guidePulseValue(.25), closeTo(1, .0001));
    expect(guidePulseValue(.01) - guidePulseValue(0), lessThan(.001));
    expect(guidePulseValue(.49), closeTo(guidePulseValue(.51), .0001));
  });

  // WHY: the card holds its place until a scrolling target collides; movement
  // completes before opacity is restored, within the owner's 800ms budget.
  // proves: CLAIM(guide-card-motion).
  // # catches: jumping during scroll, moving while opaque, fading before arrival.
  test('G: hold, fade on collision, move after stop, then restore', () {
    final m = GuideCardMotion();
    void at(int ms, double desired, {bool scrolling = false, bool collision = false}) =>
      m.place(desired, scrolling: scrolling, collision: collision, elapsed: Duration(milliseconds: ms));
    at(0, 500);
    at(100, 80);
    expect(m.top, 500, reason: 'a new preferred gap alone cannot move this step');
    at(200, 80, scrolling: true, collision: true);
    expect(m.top, 500);
    expect(m.opacity, closeTo(.2, .001));
    at(300, 80);
    at(600, 80);
    expect(m.top, inExclusiveRange(80, 500));
    expect(m.opacity, closeTo(.2, .001));
    at(900, 80);
    expect(m.top, 80);
    expect(m.opacity, closeTo(.2, .001));
    at(1000, 80);
    expect(m.top, 80);
    expect(m.opacity, inExclusiveRange(.2, 1));
    at(1100, 80);
    expect(m.opacity, 1);
    m.reset();
    at(1200, 250);
    expect(m.top, 250, reason: 'next step starts a new held position');
  });
  // WHY: the instruction must stand out on the unchanged card surfaces below it.
  // # catches: a flat material or a thick/non-theme border.
  testWidgets('G: instruction has a one pixel theme outline and medium shadow', (t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: GuideStepCard(model: const GuideCardOffPath(), onExit: () {}))));
    final material = t.widget<Material>(find.byKey(GuideStepCard.cardKey));
    expect(material.elevation, greaterThanOrEqualTo(4));
    final decoration = t.widget<DecoratedBox>(find.descendant(
      of: find.byKey(GuideStepCard.cardKey), matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;
    final border = decoration.border! as Border;
    expect(border.top.width, 1);
    expect(border.top.color, P.of(t.element(find.byKey(GuideStepCard.cardKey))).line);
  });

}
