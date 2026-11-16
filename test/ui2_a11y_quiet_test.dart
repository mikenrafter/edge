// WHY: the owner's rule (2026-11-15): only a result the USER started is spoken
// when it lands; a background calculation stays quiet. The first pilot made
// every InlineLoading status a live region, and Home builds InlineLoading for
// its automatic "Calculating today" strip, so a derive nobody asked for spoke
// over whatever the user was doing. Review round 1, finding S2.
//
// CLAIM(A11Y-QUIET): InlineLoading is readable but NOT a live region unless
// the caller says the user started the work (`announce: true`). The flag is
// what the platform turns into speech, so these tests read the semantics flag;
// takeAnnouncements() never sees live-region speech.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/sync_control.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/a11y_tree.dart';

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The one node whose spoken label holds [text], as the platform sees it.
SemanticsData _of(WidgetTester t, String text) =>
    semanticsNodes(t).singleWhere((n) => n.label.contains(text)).getSemanticsData();

void main() {
  for (final compact in [false, true]) {
    final form = compact ? 'compact' : 'card';

    testWidgets('InlineLoading ($form), by default: read, but not a live region', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(_app(InlineLoading(
          status: 'Reading last night', detail: 'day 3 of 12', compact: compact)));
      final d = _of(t, 'Reading last night');
      expect(d.hasFlag(SemanticsFlag.isLiveRegion), isFalse,
          reason: 'an automatic calculation must not speak unasked');
      expect(d.label, contains('Reading last night'), reason: 'it stays readable by swiping');
      h.dispose();
    });

    testWidgets('InlineLoading ($form), announce: true: a live region with the status', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(_app(InlineLoading(
          status: 'Saving the recording', detail: 'day 3 of 12', compact: compact, announce: true)));
      final d = _of(t, 'Saving the recording');
      expect(d.hasFlag(SemanticsFlag.isLiveRegion), isTrue,
          reason: 'the user started this work, so its status is spoken');
      expect(d.label, 'Saving the recording', reason: 'the changing day count is not spoken');
      h.dispose();
    });
  }

  testWidgets('Home\'s automatic "Calculating today" strip is quiet', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_app(
        const RingTrio(d: HomeData(), help: RingHelp.busy('Calculating today'))));
    await t.pump();
    final d = _of(t, 'Calculating today');
    expect(d.hasFlag(SemanticsFlag.isLiveRegion), isFalse,
        reason: 'a derive nobody asked for reaches this strip');
    expect(d.label, contains('Calculating today'));
    h.dispose();
  });

  testWidgets('a calculation card (CalcLoading) is quiet: it waits on background derives', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_app(const CalcLoading(status: 'Crunching last night')));
    expect(_of(t, 'Crunching last night').hasFlag(SemanticsFlag.isLiveRegion), isFalse);
    h.dispose();
  });

  testWidgets('Your data: an action the user started (busy) says what it is doing', (t) async {
    final h = t.ensureSemantics();
    t.view.physicalSize = const Size(1170, 12000); // the busy line is far down the list
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DataScreenView(busy: true, busyStatus: 'Writing the backup')));
    await t.pump();
    final d = _of(t, 'Writing the backup');
    expect(d.hasFlag(SemanticsFlag.isLiveRegion), isTrue,
        reason: 'the user tapped Back up now; its progress is theirs to hear');
    h.dispose();
  });
}
