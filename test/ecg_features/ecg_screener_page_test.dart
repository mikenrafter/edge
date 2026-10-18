// ECG features, phase 1 (RED): the screener PAGE. Content rules are pinned in
// ecg_screener_content_test.dart; this pumps EcgScreenerScreen
// (lib/ui2/screens/ecg_screener.dart) and checks what is drawn.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_links.dart';
import 'package:openstrap_edge/ecg/ecg_screener.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg_screener.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'ecg_screener_content_test.dart' show bannedIn;

Future<void> _pump(WidgetTester t, Widget home) async {
  // Tall enough that the lazy list builds every state at once.
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await t.pump();
}

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

void main() {
  testWidgets('lists every state with its title and its plain-language '
      'meaning', (t) async {
    await _pump(t, const EcgScreenerScreen());
    final text = _allText(t);
    for (final e in ecgScreenerEntries()) {
      expect(text, contains(e.title), reason: e.id);
      expect(text, contains(e.meaning), reason: e.id);
    }
  });

  testWidgets('a permanent line, not a tooltip: this is a screen, not a '
      'medical test, and nothing flagged does not mean you were cleared', (t) async {
    await _pump(t, const EcgScreenerScreen());
    final text = _allText(t).toLowerCase();
    expect(text, contains('this is a screen'));
    expect(text, contains('this is a screen, not a medical test'));
    expect(text, contains('does not mean you were cleared'));
    expect(text, contains('see a clinician'));
  });

  testWidgets('no banned vocabulary anywhere on the page, link labels '
      'included', (t) async {
    await _pump(t, const EcgScreenerScreen());
    expect(bannedIn(_allText(t)), isEmpty);
  });

  testWidgets('every link in kEcgLinks has a row; tapping it opens exactly '
      'that address', (t) async {
    final opened = <Uri>[];
    await _pump(t, EcgScreenerScreen(openUrl: (u) async => opened.add(u)));
    for (final l in kEcgLinks) {
      expect(find.byKey(ValueKey('ecg-link:${l.stateId}:${l.ref}')),
          findsOneWidget,
          reason: '${l.stateId} ${l.ref}');
    }
    final first = kEcgLinks.first;
    await t.tap(find.byKey(ValueKey('ecg-link:${first.stateId}:${first.ref}')));
    await t.pump();
    expect(opened, [Uri.parse(first.url)]);
  });

  testWidgets('a state with no literature shows no link row (partial, failed)',
      (t) async {
    await _pump(t, const EcgScreenerScreen());
    expect(find.byKey(const ValueKey('ecg-states:partial')), findsOneWidget);
    expect(find.byKey(const ValueKey('ecg-states:failed')), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey &&
          ('${(w.key as ValueKey).value}'.startsWith('ecg-link:partial:') ||
              '${(w.key as ValueKey).value}'.startsWith('ecg-link:failed:'))),
      findsNothing,
    );
  });

  testWidgets('"not screened" states look different from "nothing flagged" '
      'ones: they are marked in the page by key', (t) async {
    await _pump(t, const EcgScreenerScreen());
    for (final e in ecgScreenerEntries()) {
      final marker = find.descendant(
        of: find.byKey(ValueKey('ecg-states:${e.id}')),
        matching: find.byKey(const ValueKey('ecg-not-screened')),
      );
      expect(marker, e.screened ? findsNothing : findsOneWidget, reason: e.id);
    }
  });
}
