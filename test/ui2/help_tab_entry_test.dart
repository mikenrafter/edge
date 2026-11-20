import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/guides/help_entry.dart';
import '../support/skeleton_fixture.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/guide_r2_scenes.dart' show r2OpenDb, r2Tab;
import '../support/live_guide_harness.dart';

const _labels = {
  "en": ("Looking for something?", "All guides"),
  "de": ("Suchst du etwas?", "Alle Anleitungen"),
  "es": ("¿Buscas algo?", "Todas las guías"),
  "fr": ("Vous cherchez quelque chose ?", "Tous les guides"),
  "hi": ("कुछ ढूँढ रहे हैं?", "सभी गाइड"),
  "ru": ("Что-то ищете?", "Все руководства"),
  "zh": ("在找什么吗？", "所有指南"),
  "th": ("กำลังมองหาอะไรอยู่ไหม?", "คู่มือทั้งหมด"),
};

const _ids = {
  GuideTopic.today: ['heart-rate-zones', 'remove-detected'],
  GuideTopic.sleep: ['alarm-schedule', 'add-nap', 'fix-sleep-times'],
  GuideTopic.activity: ['delete-workout', 'start-workout', 'log-past-workout'],
  GuideTopic.health: <String>[],
};
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await r2OpenDb('help_tab_entry_test.db');
  });
  tearDownAll(LocalDb.close);
  for (final topic in GuideTopic.values) {
    // WHY: each production tab needs a reachable, stable footer that opens its own guides, with a way to all eight.
    // catches: a missing footer, wrong topic, or content covered by navigation.
    testWidgets('${topic.name} bottom opens its guides and All guides', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      try {
        await pumpLiveGuideApp(t, brightness: Brightness.dark);
        await t.tap(r2Tab(topic.index));
        await settleLiveGuide(t);
        for (
          var i = 0;
          i < 30 && t.any(find.byType(CircularProgressIndicator));
          i++
        ) {
          await settleLiveGuide(t, frames: 4);
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final button = find.widgetWithText(
          TextButton,
          'Looking for something?',
        );
        // Scroll as a user does while the lazy sleep plan finishes its reads.
        for (var i = 0; i < 40; i++) {
          if (button.hitTestable().evaluate().isNotEmpty &&
              !t.any(find.byType(CircularProgressIndicator))) {
            break;
          }
          await t.drag(find.byType(Scrollable).first, const Offset(0, -400));
          await settleLiveGuide(t);
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(button.hitTestable(), findsOneWidget);
        final list = t.widget<ListView>(
          find.ancestor(of: button, matching: find.byType(ListView)).first,
        );
        final last =
            (list.childrenDelegate as SliverChildListDelegate).children.last;
        expect(
          find.descendant(of: find.byWidget(last), matching: button),
          findsOneWidget,
          reason: 'Help follows the last content item in the scroll view',
        );
        // A tappable centre can leave the last few pixels behind the tab bar.
        // Scroll the whole button into view before checking its full bounds.
        await t.ensureVisible(button);
        await settleLiveGuide(t);
        final rect = t.getRect(button);
        expect(rect.width, 358); // 390 px viewport, 16 px padding on each side.
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(
          rect.bottom,
          lessThan(780),
          reason: 'above the persistent bottom navigation',
        );
        final node = t.getSemantics(button).getSemanticsData();
        expect(node.label, 'Open Help for ${['Today', 'Sleep', 'Activity', 'Health'][topic.index]}');
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.hasAction(SemanticsAction.tap), isTrue);
        await settleLiveGuide(t);
        expect(
          t.getRect(button),
          rect,
          reason: 'settled content does not move the footer',
        );
        await t.tap(button);
        await settleLiveGuide(t);
        expect(find.byType(HelpScreen), findsOneWidget);
        for (final entry in _ids.entries) {
          for (final id in entry.value) {
            expect(
              find.byKey(HelpScreen.guideRowKey(id)),
              entry.key == topic ? findsOneWidget : findsNothing,
            );
          }
        }
        if (topic == GuideTopic.health) {
          expect(
            find.text('There are no guides for this tab yet.'),
            findsOneWidget,
          );
        }
        await t.tap(find.widgetWithText(TextButton, 'All guides'));
        await settleLiveGuide(t);
        t.view.physicalSize = const Size(390, 1800);
        await t.pump();
        // All guide rows are built in the detail scaffold, including those below the viewport.
        for (final id in _ids.values.expand((ids) => ids)) {
          expect(find.byKey(HelpScreen.guideRowKey(id)), findsOneWidget);
        }
        expect(t.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
  for (final locale in AppLocalizations.supportedLocales) {
    // why: long translations at the largest text size must wrap, with the full button still tappable.
    testWidgets('${locale.languageCode} footer wraps at large text size', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      try {
      skTallView(t, w: 320, h: 844);
      await t.pumpWidget(
        skHost(
          Scaffold(
            body: Builder(
              builder: (c) => MediaQuery(
                data: MediaQuery.of(
                  c,
                ).copyWith(textScaler: TextScaler.linear(3.1)),
                child: const Align(
                  alignment: Alignment.bottomCenter,
                  child: HelpEntry(topic: GuideTopic.sleep),
                ),
              ),
            ),
          ),
          locale: locale,
        ),
      );
      await t.pump();
      final label = _labels[locale.languageCode]!.$1;
      final button = find.widgetWithText(TextButton, label);
      expect(button.hitTestable(), findsOneWidget);
      final reviewed = jsonDecode(File('test/fixtures/help_review_copy.json').readAsStringSync()) as Map<String, dynamic>;
      // Thai has no reviewed-copy snapshot (test/fixtures/help_review_copy.json
      // lists en, de, es, fr, hi, ru, zh), so it is checked against its own ARB.
      final l = lookupAppLocalizations(locale);
      final reviewedName = reviewed[locale.languageCode]?['helpOpenForTab'] as String?;
      final expectedName = reviewedName == null
          ? l.helpOpenForTab(l.tabSleep)
          : reviewedName.replaceAll('{tab}', l.tabSleep);
      expect(t.getSemantics(button).getSemanticsData().label, expectedName);
      expect(t.getRect(button).left, greaterThanOrEqualTo(0));
      expect(t.getRect(button).right, lessThanOrEqualTo(320));
      expect(t.getSize(button).height, greaterThanOrEqualTo(48));
      expect(t.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
  // why: every supported language needs translated discovery and escape labels.
  test('Help entry labels are translated in every supported locale', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final arb = jsonDecode(File('lib/l10n/app_${locale.languageCode}.arb').readAsStringSync()) as Map<String, dynamic>;
      expect(arb['helpLookingForSomething'], _labels[locale.languageCode]!.$1);
      expect(arb['helpAllGuides'], _labels[locale.languageCode]!.$2);
      expect(arb['helpTopicEmpty'], isA<String>());
      if (locale.languageCode != 'en') {
        expect(arb['helpLookingForSomething'], isNot('Looking for something?'));
        expect(arb['helpAllGuides'], isNot('All guides'));
        expect(
          arb['helpTopicEmpty'],
          isNot('There are no guides for this tab yet.'),
        );
      }
    }
  });
}
