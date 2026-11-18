import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_filter.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_filter_button.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;
import '../support/pin_tz.dart';

void main() {
  pinProcessTimeZone('UTC');
  setUpAll(skLoadAppFonts);
  // WHY: a translated count must describe the two active kinds; long labels
  // and 2x text must keep every control reachable (spec §4.5/§6.3).
  // Catches: English-only semantics, wrapping overflow, last-kind deselection.
  testWidgets(
    'all eight locales at 320/412 and 1x/2x expose selected count and usable sheet',
    (t) async {
      const labels = {
        'en': 'Filter, 2 kinds selected',
        'de': 'Filter, 2 Arten ausgewählt',
        'es': 'Filtro, 2 tipos seleccionados',
        'fr': 'Filtre, 2 types sélectionnés',
        'hi': 'फ़िल्टर, 2 प्रकार चुने गए',
        'ru': 'Фильтр, выбрано типов: 2',
        'th': 'ตัวกรอง เลือกไว้ 2 ประเภท',
        'zh': '筛选，已选择 2 类',
      };
      const singular = {
        'en': 'Filter, 1 kind selected',
        'de': 'Filter, 1 Art ausgewählt',
        'es': 'Filtro, 1 tipo seleccionado',
        'fr': 'Filtre, 1 type sélectionné',
        'hi': 'फ़िल्टर, 1 प्रकार चुना गया',
        'ru': 'Фильтр, выбрано типов: 1',
        'th': 'ตัวกรอง เลือกไว้ 1 ประเภท',
        'zh': '筛选，已选择 1 类',
      };
      final semantics = t.ensureSemantics();
      for (final locale in labels.keys) {
        for (final width in [320.0, 412.0]) {
          for (final scale in [1.0, 2.0]) {
            t.view.physicalSize = Size(width, 850);
            t.view.devicePixelRatio = 1;
            final controller = TimelineController(
              homeStartSec: 0,
              homeEndSec: 86400,
            );
            final filter = TimelineFilter();
            await t.pumpWidget(
              MaterialApp(
                locale: Locale(locale),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: buildTheme(Brightness.light),
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: Column(
                        children: [
                          timelineChart(
                            controller: controller,
                            graph: DayGraph(
                              dayStart: 0,
                              hr: List.filled(1440, 60),
                            ),
                            annotations: const [],
                            onAnnotationSelected: (_) {},
                          ),
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            children: [
                              TimelineZoomControls(controller: controller),
                              TimelineFilterButton(filter: filter),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            expect(
              find.bySemanticsLabel(labels[locale]!),
              findsOneWidget,
              reason: '$locale/$width/$scale',
            );
            filter.setKinds({DayTimelineKind.pending});
            await t.pump();
            expect(find.bySemanticsLabel(singular[locale]!), findsOneWidget);
            filter.setKinds(DayTimelineKind.values.toSet());
            await t.pump();
            expect(
              find.bySemanticsLabel(labels[locale]!.replaceAll('2', '3')),
              findsOneWidget,
            );
            filter.setKinds({DayTimelineKind.pending, DayTimelineKind.saved});
            await t.pump();
            expect(
              t
                  .getSemantics(find.bySemanticsLabel(labels[locale]!))
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isTrue,
            );
            final translated = lookupAppLocalizations(Locale(locale));
            expect(
              find.text('${translated.dayTimelineHeartRateTitle} (bpm)'),
              findsOneWidget,
            );
            expect(find.text(translated.timelineMovementShare), findsOneWidget);
            final button = find.byKey(const ValueKey('timeline-filter'));
            expect(t.getSize(button).height, greaterThanOrEqualTo(48));
            await t.ensureVisible(button);
            await t.pump();
            t.semantics.tap(find.semantics.byLabel(labels[locale]!));
            await t.pumpAndSettle();
            for (final kind in DayTimelineKind.values) {
              final row = find.byKey(ValueKey('timeline-kind:${kind.name}'));
              expect(row, findsOneWidget);
              await t.ensureVisible(row);
              await t.pump();
              expect(t.getSize(row).height, greaterThanOrEqualTo(48));
            }
            expect(t.takeException(), isNull, reason: '$locale/$width/$scale');
            await t.pumpWidget(const SizedBox());
            controller.dispose();
            filter.dispose();
          }
        }
      }
      semantics.dispose();
      t.view.reset();
    },
  );
}
