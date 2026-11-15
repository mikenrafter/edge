// WHY: merging the guide hover and no-spinners work must preserve A11Y-NODE,
// target-owned hover paint, measured presses and PendingUserAction activation.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/a11y_tree.dart';
import 'support/guide_text.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  for (final kind in ['text', 'label', 'hold']) {
    // catches: dropping GuideUnitMark, hiding its hover, duplicating semantics,
    // or sending screen-reader taps directly to onTap, bypassing _activate.
    testWidgets('$kind control paints its hover and keeps one working node', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final controller = GuideDimController();
      final boundaryKey = GlobalKey();
      final actions = <bool>[];
      final contacts = <String>[];
      await t.pumpWidget(
        _host(
          GuideDimScope(
            controller: controller,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Pressable(
                semanticLabel: kind == 'text' ? null : 'Open details',
                selected: true,
                expanded: false,
                onTap: () => actions.add(PendingUserAction.active),
                onPressStart: kind == 'hold'
                    ? () => contacts.add('start')
                    : null,
                onPressEnd: kind == 'hold' ? () => contacts.add('end') : null,
                onPressCancel: kind == 'hold'
                    ? () => contacts.add('cancel')
                    : null,
                child: const SizedBox(
                  width: 160,
                  height: 80,
                  child: ColoredBox(
                    color: C.n600,
                    child: Center(child: Text('Open details')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final mark = t.renderObject<RenderGuideUnit>(find.byType(GuideUnitMark));
      expect(
        guideHoverMark(t.renderObject<RenderBox>(find.byType(Pressable))),
        same(mark),
      );
      Future<int> pixel() async => (await t.runAsync(() async {
        final image = await t
            .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
            .toImage();
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return bytes.getUint32((10 * image.width + 10) * 4);
        } finally {
          image.dispose();
        }
      }))!;
      final before = await pixel();
      controller.setHovers({
        mark: GuideHover(Offset.zero & mark.size, 6, C.blue)..value = 1,
      });
      await t.pump();
      expect(
        await pixel(),
        isNot(before),
        reason: 'the actual control paints the hover',
      );
      final node = t.getSemantics(find.byType(Pressable));
      expect(node.label, 'Open details');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isSelected == ui.Tristate.isTrue, isTrue);
      expect(node.flagsCollection.isExpanded != ui.Tristate.none, isTrue);
      expect(node.flagsCollection.isExpanded == ui.Tristate.isTrue, isFalse);
      expect(
        semanticsNodes(
          t,
        ).where((n) => n.getSemanticsData().hasAction(SemanticsAction.tap)),
        [node],
        reason: 'one actionable node, including on the measured-press path',
      );
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          viewId: t.view.viewId,
          nodeId: node.id,
          type: SemanticsAction.tap,
        ),
      );
      expect(actions, [
        true,
      ], reason: 'TalkBack activation records a user action');
      await t.pump();
      expect(
        PendingUserAction.active,
        isFalse,
        reason: 'intent clears after the frame',
      );
      if (kind == 'hold') {
        final gesture = await t.startGesture(
          t.getCenter(find.byType(Pressable)),
        );
        await t.pump();
        expect(t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, .975);
        await gesture.up();
        await t.pump();
        expect(t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
        final cancelled = await t.startGesture(
          t.getCenter(find.byType(Pressable)),
        );
        await cancelled.cancel();
        await t.pump();
        expect(contacts, ['start', 'end', 'start', 'cancel']);
        expect(actions, [
          true,
        ], reason: 'raw contact callbacks do not duplicate onTap');
      } else {
        await t.tap(find.byType(Pressable));
        expect(actions, [
          true,
          true,
        ], reason: 'pointer activation records a user action too');
      }
      controller.clearHovers();
      await t.pump();
      await t.pumpAndSettle();
      expect(
        await pixel(),
        before,
        reason: 'ending the guide removes the hover',
      );
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      semantics.dispose();
    });
  }

  // catches: a second button node around Pressable, a stale expanded flag,
  // or replacing remembered toggleSection with an ephemeral local toggle.
  testWidgets(
    'guide help has one expandable node and remembers TalkBack toggles',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      await Prefs.setBoolAcked('accordion_guide_missing_help', false);
      final semantics = t.ensureSemantics();
      Widget card() => _host(
        GuideStepCard(
          model: GuideCardOnStep(
            number: 1,
            total: 2,
            caption: 'Open details.',
            missingHelp: GuideFooter(
              kind: GuideFooterKind.missingTarget,
              title: fnText((_) => 'Missing details'),
              body: fnText((_) => 'Sign in first.'),
            ),
          ),
          onExit: () {},
        ),
      );
      final control = find.byKey(GuideStepCard.dontSeeItKey);
      void check(bool expanded) {
        final node = t.getSemantics(control);
        final data = node.getSemanticsData();
        expect(data.label, "Don't see it?");
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isExpanded != ui.Tristate.none, isTrue);
        expect(data.flagsCollection.isExpanded == ui.Tristate.isTrue, expanded);
        expect(
          semanticsNodes(t).where((n) => n.label.contains("Don't see it?")),
          [node],
        );
        expect(
          find.byKey(GuideStepCard.missingHelpKey),
          expanded ? findsOneWidget : findsNothing,
        );
      }

      await t.pumpWidget(card());
      check(false);
      t.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          viewId: t.view.viewId,
          nodeId: t.getSemantics(control).id,
          type: SemanticsAction.tap,
        ),
      );
      await t.pumpAndSettle();
      await t.runAsync(() => SettingsRepository.instance.read());
      check(true);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(card());
      check(true);
      await t.tap(control);
      await t.pumpAndSettle();
      await t.runAsync(() => SettingsRepository.instance.read());
      check(false);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(card());
      check(false);
      semantics.dispose();
    },
  );
}
