// WHY: TalkBack reads the semantics tree, and the shared widgets decide most of
// it. Before the pilot a BigButton said "Save, Save", a greyed button read as
// plain text, a selected tab did not say "selected", section titles were no
// headings, and a section of cards was one long utterance (probe 1 and probe 2,
// edge.research/a11y-inventory.md). Each test pins one claim on the real
// widget; each one fails on the base commit (77d19df82).
//
// CLAIM(A11Y-NODE) one node per control, read once; a card is its own stop.
// CLAIM(A11Y-STATE) disabled / selected / expanded / busy are spoken.
// CLAIM(A11Y-HEAD) section, tab and page titles are headings; a pushed page names its route.
// CLAIM(A11Y-LIVE) InlineLoading's status is a live region; its day count is not.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/a11y_tree.dart';

Widget _host(List<Widget> children, {bool nav = false}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SafeArea(
          child: Column(children: [
            if (nav) const NavBar('Sleep detail', sub: 'Tue 3 Nov'),
            Expanded(child: ListView(children: children)),
          ]),
        ),
      ),
    );

SemanticsData _data(WidgetTester t, Finder f) => t.getSemantics(f).getSemanticsData();

void main() {
  late SemanticsHandle h;
  setUp(() => h = SemanticsBinding.instance.ensureSemantics());
  tearDown(() => h.dispose());

  testWidgets('BigButton is one button node read once', (t) async {
    await t.pumpWidget(_host([BigButton('Save', onTap: () {})]));
    final d = _data(t, find.byType(Pressable));
    expect(d.label, 'Save', reason: 'base: "Save\\nSave", read twice');
    expect(d.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(d.hasAction(SemanticsAction.tap), isTrue);
  });

  testWidgets('a greyed BigButton is a disabled button, not plain text', (t) async {
    await t.pumpWidget(_host([const BigButton('Save', onTap: null)]));
    final d = _data(t, find.byType(Pressable));
    expect(d.label, 'Save');
    expect(d.hasFlag(SemanticsFlag.isButton), isTrue, reason: 'base: no flags at all');
    expect(d.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(d.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(d.hasAction(SemanticsAction.tap), isFalse);
  });

  testWidgets('a busy BigButton says the work is under way', (t) async {
    await t.pumpWidget(_host([BigButton('Save', busy: true, onTap: () {})]));
    expect(_data(t, find.byType(Pressable)).label, 'Save, working');
  });

  testWidgets('a BigButton with press callbacks keeps its tap action', (t) async {
    var taps = 0;
    await t.pumpWidget(_host([
      BigButton('Hold', onTap: () => taps++, onPressStart: () {}, onPressEnd: () {}),
    ]));
    final n = t.getSemantics(find.byType(Pressable));
    expect(n.label, 'Hold');
    t.binding.pipelineOwner.semanticsOwner!
        .performAction(n.id, SemanticsAction.tap);
    expect(taps, 1, reason: 'the screen reader tap still reaches onTap');
  });

  testWidgets('a labelled Pressable speaks its label, not its child text too', (t) async {
    await t.pumpWidget(_host([
      Pressable(
        onTap: () {},
        semanticLabel: 'Open sleep, 7 h 30 min',
        child: const Text('Sleep'),
      ),
    ]));
    expect(_data(t, find.byType(Pressable)).label, 'Open sleep, 7 h 30 min');
  });

  testWidgets('the screen reader tap on a labelled Pressable reaches onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(_host([
      Pressable(onTap: () => taps++, semanticLabel: 'Open', child: const Text('x')),
    ]));
    final n = t.getSemantics(find.byType(Pressable));
    t.binding.pipelineOwner.semanticsOwner!.performAction(n.id, SemanticsAction.tap);
    expect(taps, 1);
  });

  testWidgets('SubTabs: the active pill is selected, a disabled one is a disabled button', (t) async {
    await t.pumpWidget(_host([
      SubTabs(const ['Day', 'Week', 'Month'], 0, (_) {}, disabled: const {2}),
    ]));
    final day = _data(t, find.text('Day'));
    final week = _data(t, find.text('Week'));
    final month = _data(t, find.text('Month'));
    expect(day.hasFlag(SemanticsFlag.isSelected), isTrue, reason: 'base: no selected flag');
    expect(week.hasFlag(SemanticsFlag.hasSelectedState), isTrue);
    expect(week.hasFlag(SemanticsFlag.isSelected), isFalse);
    expect(month.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(month.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(month.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(month.label, 'Month, unavailable', reason: 'the label still says why');
  });

  testWidgets('Section: the title is a heading node of its own', (t) async {
    await t.pumpWidget(_host([Section('Stages', const Text('body'))]));
    final title = _data(t, find.text('Stages'));
    expect(title.label, 'Stages', reason: 'base: "Stages\\nbody"');
    expect(title.hasFlag(SemanticsFlag.isHeader), isTrue);
  });

  testWidgets('a Section of StatusCards: a heading, then one stop per card', (t) async {
    await t.pumpWidget(_host([
      Section(
          'Stages',
          Column(children: const [
            StatusCard('Not enough nights', 'Needs 7 nights of sleep.'),
            StatusCard('Band not connected', 'Pair it to score.'),
          ])),
    ]));
    final labels = spokenLabels(t);
    expect(labels, containsAllInOrder([
      'Stages',
      'Not enough nights. Needs 7 nights of sleep.',
      'Band not connected. Pair it to score.',
    ]), reason: 'base: one node "Stages | card | card text | card | card text"');
    expect(repeatedLines(t), isEmpty);
  });

  testWidgets('plain cards in one list child are separate stops', (t) async {
    await t.pumpWidget(_host([
      Column(children: const [
        Surface(child: Text('First card')),
        Surface(child: Text('Second card')),
      ]),
    ]));
    expect(spokenLabels(t), containsAllInOrder(['First card', 'Second card']));
  });

  testWidgets('a plain card inside a control adds its text to that control', (t) async {
    await t.pumpWidget(_host([
      Pressable(onTap: () {}, child: const Surface(child: Text('Open details'))),
    ]));
    final d = _data(t, find.byType(Pressable).first);
    expect(d.label, 'Open details', reason: 'the button keeps a name');
    expect(d.hasFlag(SemanticsFlag.isButton), isTrue);
  });

  testWidgets('NavBar: the title is a heading that names the route', (t) async {
    await t.pumpWidget(_host(const [Text('x')], nav: true));
    final d = _data(t, find.text('Sleep detail'));
    expect(d.label, 'Sleep detail');
    expect(d.hasFlag(SemanticsFlag.isHeader), isTrue);
    expect(d.hasFlag(SemanticsFlag.namesRoute), isTrue);
  });

  testWidgets('ScreenTitle is a heading', (t) async {
    await t.pumpWidget(_host(const [ScreenTitle('Sleep')]));
    final d = _data(t, find.text('Sleep'));
    expect(d.hasFlag(SemanticsFlag.isHeader), isTrue);
  });

  testWidgets('SettingsAccordion: the state is a flag, the rows are not in its label', (t) async {
    await t.pumpWidget(_host([
      SettingsAccordion('Sleep', summary: 'Goal 8 h', children: const [Text('row one')]),
    ]));
    // Open by default.
    var d = _data(t, find.byType(Pressable).first);
    expect(d.hasFlag(SemanticsFlag.hasExpandedState), isTrue);
    expect(d.hasFlag(SemanticsFlag.isExpanded), isTrue);
    expect(d.label, 'Sleep', reason: 'base: "Sleep, expanded" + the title again');
    expect(d.label.contains('row one'), isFalse, reason: 'base: the row was read inside the header button');
    await t.tap(find.text('Sleep'));
    await t.pumpAndSettle();
    d = _data(t, find.byType(Pressable).first);
    expect(d.hasFlag(SemanticsFlag.isExpanded), isFalse);
    expect(d.label, 'Sleep, Goal 8 h');
    await t.tap(find.text('Sleep'));
    await t.pumpAndSettle();
    expect(spokenLabels(t), contains('row one'));
  });

  testWidgets('DayNav at its newest day: the arrow is a disabled button and names no row', (t) async {
    await t.pumpWidget(_host([
      DayNav(day: '2026-11-15', days: const ['2026-11-15', '2026-11-14'], onDay: (_) {}),
    ]));
    final next = t.getSemantics(find.bySemanticsLabel('Next day'));
    final d = next.getSemanticsData();
    expect(d.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(d.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(d.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    var hasButtonChild = false;
    next.visitChildren((c) {
      hasButtonChild = true;
      return true;
    });
    expect(hasButtonChild, isFalse, reason: 'base: the row was named "Next day" and held the working buttons');
  });

  // Default quiet, announce: true live: test/ui2_a11y_quiet_test.dart.
  testWidgets('InlineLoading (announce: true): the status is a live region; the day count is outside it', (t) async {
    await t.pumpWidget(_host([
      const InlineLoading(status: 'Reading last night', detail: 'day 3 of 12', announce: true),
    ]));
    final d = _data(t, find.text('Reading last night'));
    expect(d.label, 'Reading last night');
    expect(d.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    expect(spokenLabels(t).any((l) => l.contains('day 3 of 12')), isTrue,
        reason: 'the detail is still readable, just not announced on every change');
  });

  testWidgets('no node repeats a line: the probe-2 page', (t) async {
    await t.pumpWidget(_host([
      Section('Stages', Column(children: const [
        StatusCard('Not enough nights', 'Needs 7 nights of sleep.'),
        StatusCard('Band not connected', 'Pair it to score.', fix: 'Pair a band'),
      ])),
      const InlineLoading(status: 'Reading last night', detail: 'day 3 of 12'),
      DayNav(day: '2026-11-15', days: const ['2026-11-15', '2026-11-14'], onDay: (_) {}),
      SettingsAccordion('Sleep', summary: 'Goal 8 h', children: const [Text('row one')]),
      BigButton('Save', onTap: () {}),
      InsightCard('Bed earlier', 'Three short nights.', action: 'See why', onTap: () {}),
    ], nav: true));
    expect(repeatedLines(t), isEmpty);
  });

  testWidgets('opt-in 48 dp targets: an icon Pressable is 48 x 48 on Android, 44 without the opt-in', (t) async {
    // CLAIM(A11Y-TAP48): the pilot opt-in raises only the Pressable minimum.
    Widget icon() => Center(child: Pressable(
        onTap: () {}, semanticLabel: 'Close', child: const Icon(Icons.close, size: 18)));
    // Away from the screen edge: the guideline skips nodes touching it.
    final page = [const SizedBox(height: 100), icon()];
    await t.pumpWidget(_host(page));
    expect(t.getSize(find.byType(Pressable)), const Size(44, 44));
    expect((await androidTapTargetGuideline.evaluate(t)).passed, isFalse,
        reason: 'positive control: 44 fails the Android guideline');
    Pressable.debugTap48 = true;
    addTearDown(() => Pressable.debugTap48 = null);
    await t.pumpWidget(_host([const SizedBox(height: 100), icon()]));
    expect(t.getSize(find.byType(Pressable)), const Size(48, 48));
    await expectLater(t, meetsGuideline(androidTapTargetGuideline));
  });

  testWidgets('the repeated-line check catches what it is for', (t) async {
    // Positive control for repeatedLines: a hand-built doubled label.
    await t.pumpWidget(_host([
      Semantics(container: true, label: 'Save', child: const Text('Save')),
    ]));
    expect(repeatedLines(t), isNotEmpty);
  });
}
