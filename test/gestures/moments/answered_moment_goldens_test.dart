// Goldens for editing an answered marked moment (CLS-1), light and dark.
//
// What they pin (reviewed by eye when generated, 2026-10-27):
//   * answered_rows: the day-list card of an answered moment before and after
//     its answer changed (caffeine -> alcohol, no notes), with its persistent
//     Edit. The two rows are the same height; asserted below by measurement as
//     well, because a golden only shows it to a person.
//   * edit_caffeine: the editor opened on a caffeine answer, amount filled in.
//   * edit_symptom: the editor opened on a symptom answer, description filled in.
//   * edit_refused: the reason shown when the answer changed somewhere else.
// Generated with `flutter test --update-goldens`; the card around the row mirrors
// DayTimelineScreen._dayRows (the live screen is covered by
// answered_moment_edit_ui_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/bundled_fonts.dart';
import '../../support/pin_tz.dart';

class _NoEditor implements DayRowEditListener {
  @override
  Future<void> openRowEditor(Moment m) async {}
  @override
  Future<void> reloadDay() async {}
}

class _Refuses extends MomentAnswerWriter {
  const _Refuses(this.result);
  final MomentAnswerChange result;
  @override
  Future<MomentAnswerChange> change(MomentLabel saved, MomentChoice choice,
          {double? value,
          String? note,
          SymptomDescription? symptom,
          DateTime? now}) async =>
      result;
}

const _caffeine = MomentLabel(
    date: '2026-10-06',
    hhmm: '10:15',
    label: 'caffeine',
    caffeineMg: 80,
    metricValue: 80,
    answeredAtMs: 1);
const _symptomLabel = MomentLabel(
    date: '2026-10-06', hhmm: '13:00', label: 'symptom', answeredAtMs: 1);
const _knee = SymptomDescription(
  severity: SymptomSeverity.moderate,
  side: SymptomSide.left,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);

Moment _row(String key, String title, IconData icon, int hour, int minute) =>
    Moment(
      at: DateTime(2026, 10, 6, hour, minute).millisecondsSinceEpoch ~/ 1000,
      identity: 'moment:$key',
      editRef: 'moment:$key',
      title: title,
      icon: icon,
      color: C.domMind,
    );

Widget _card(BuildContext c, Moment m, String key) {
  final p = P.of(c);
  return Container(
    key: ValueKey('card:$key'),
    margin: const EdgeInsets.symmetric(vertical: S.x1),
    padding: const EdgeInsets.symmetric(horizontal: S.x3),
    decoration:
        BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(R.md)),
    child: MomentRow(m,
        below: DayReviewActions(
            controller: null, id: 'moment:$key', moment: m, editor: _NoEditor())),
  );
}

void main() {
  pinProcessTimeZone('America/Denver');
  setUpAll(loadFonts);
  // 24 h, as the review harness: the clock column is one line, so the rows
  // show the answer and not a wrapped "AM".
  setUp(() => ClockFormatController.seed(ClockFormat.h24));

  for (final brightness in Brightness.values) {
    final mode = brightness.name;

    testWidgets('answered rows before and after a change, $mode', (t) async {
      final boundary = GlobalKey();
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 400);
      addTearDown(t.view.reset);
      final before = _row('2026-10-06 10:15', 'Caffeine', LucideIcons.coffee, 10, 15);
      final after = _row('2026-10-06 10:15', 'Alcohol', LucideIcons.wine, 10, 15);
      final other = _row('2026-10-06 20:45', 'Other', LucideIcons.bookmark, 20, 45);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness),
        home: RepaintBoundary(
          key: boundary,
          child: Builder(
            builder: (c) => Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(S.x4),
                child: Column(children: [
                  _card(c, before, 'a'),
                  _card(c, after, 'b'),
                  _card(c, other, 'c'),
                ]),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      expect(t.getSize(find.byKey(const ValueKey('card:a'))).height,
          t.getSize(find.byKey(const ValueKey('card:b'))).height,
          reason: 'the same row after its answer changed is the same height');
      expect(find.text('Edit'), findsNWidgets(3));
      await expectLater(find.byKey(boundary),
          matchesGoldenFile('../../fixtures/cls1_goldens/answered_rows_$mode.png'));
    });

    testWidgets('editor on a caffeine answer, $mode', (t) async {
      final boundary = GlobalKey();
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 640);
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness),
        home: RepaintBoundary(
            key: boundary, child: const MomentAnswerEditScreen(saved: _caffeine)),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(boundary),
          matchesGoldenFile('../../fixtures/cls1_goldens/edit_caffeine_$mode.png'));
    });
  }

  testWidgets('editor on a symptom answer, light', (t) async {
    final boundary = GlobalKey();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 1000);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: RepaintBoundary(
          key: boundary,
          child: MomentAnswerEditScreen(
              saved: _symptomLabel,
              symptom: StoredSymptom(
                  date: '2026-10-06', hhmm: '13:00', description: _knee))),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(boundary),
        matchesGoldenFile('../../fixtures/cls1_goldens/edit_symptom_light.png'));
  });

  testWidgets('editor showing why a change was refused, dark', (t) async {
    final boundary = GlobalKey();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 640);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: RepaintBoundary(
          key: boundary,
          child: MomentAnswerEditScreen(
              saved: _caffeine, writer: _Refuses(MomentStale(_caffeine)))),
    ));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('moment-edit-save')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('moment-edit-error')), findsOneWidget);
    await expectLater(find.byKey(boundary),
        matchesGoldenFile('../../fixtures/cls1_goldens/edit_refused_dark.png'));
  });
}
