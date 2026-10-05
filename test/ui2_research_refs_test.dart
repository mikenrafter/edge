// Research citations: the table, and the links drawn from it.
//
// A reference with no DOI on record stays plain text — a link built from a
// guessed DOI is worse than no link (docs/research-references.md records where
// each DOI came from).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Builder(builder: (_) => child)),
    );

Finder _link(String label) => find.byWidgetPredicate(
    (w) => w is Pressable && w.link && w.semanticLabel == label);

void main() {
  group('table', () {
    test('ids and labels are unique', () {
      expect({for (final r in kResearchRefs) r.id}.length, kResearchRefs.length);
      expect({for (final r in kResearchRefs) r.label}.length,
          kResearchRefs.length);
    });

    test('every DOI is bare and well formed', () {
      final withDoi = kResearchRefs.where((r) => r.doi != null).toList();
      expect(withDoi, isNotEmpty);
      for (final r in withDoi) {
        expect(r.doi, matches(RegExp(r'^10\.\d{4,9}/\S+$')), reason: r.id);
        expect(r.doi, isNot(contains('doi.org')), reason: r.id);
        expect(r.doi, isNot(startsWith('doi:')), reason: r.id);
        expect(r.url, 'https://doi.org/${r.doi}', reason: r.id);
      }
    });

    test('a reference with neither DOI nor link has no URL', () {
      for (final r in kResearchRefs.where((r) => r.doi == null && r.link == null)) {
        expect(r.url, isNull, reason: r.id);
      }
    });

    test('a non-DOI link is https, and never sits beside a DOI', () {
      final linked = kResearchRefs.where((r) => r.link != null).toList();
      expect(linked, isNotEmpty);
      for (final r in linked) {
        expect(r.doi, isNull, reason: r.id);
        expect(r.link, startsWith('https://'), reason: r.id);
        expect(r.url, r.link, reason: r.id);
      }
    });
  });

  group('provenance record', () {
    test('only the reference with no confirmed source stays plain text', () {
      final noUrl = {for (final r in kResearchRefs.where((r) => r.url == null)) r.id};
      expect(noUrl, {'baevsky2008'});
    });
  });

  group('researchCitation', () {
    testWidgets('each linked citation opens exactly its doi.org URL',
        (t) async {
      for (final r in kResearchRefs.where((r) => r.url != null)) {
        final opened = <String>[];
        await t.pumpWidget(_host(Builder(
          builder: (c) => researchCitation(c, 'Something else · ${r.label}',
              open: (u) async {
            opened.add(u);
            return true;
          }),
        )));
        final link = _link(r.label);
        expect(link, findsOneWidget, reason: r.id);
        await t.tap(link);
        expect(opened, [r.url], reason: r.id);
      }
    });

    testWidgets('a link is announced as a link, labelled with the reference',
        (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_host(Builder(
        builder: (c) => researchCitation(c, 'Straczkiewicz 2023'),
      )));
      final node = t.getSemantics(find.byType(Pressable));
      expect(node.flagsCollection.isLink, isTrue);
      expect(node.flagsCollection.isButton, isFalse);
      expect(node.label, 'Straczkiewicz 2023');
      handle.dispose();
    });

    testWidgets('a reference without a DOI is plain text, not a link',
        (t) async {
      await t.pumpWidget(_host(Builder(
        builder: (c) => researchCitation(c, 'Baevsky 2008 · Hopkins smallest-worthwhile-change gate'),
      )));
      expect(_link('Baevsky 2008'), findsNothing);
      expect(find.byType(Pressable), findsNothing);
      expect(find.text('Baevsky 2008 · Hopkins smallest-worthwhile-change gate'),
          findsOneWidget);
    });

    testWidgets('only the part naming a linked study is tappable',
        (t) async {
      final opened = <String>[];
      await t.pumpWidget(_host(Builder(
        builder: (c) => researchCitation(
            c, 'AN-2554 pedometer · O\'Connell 2017 · Baevsky 2008',
            open: (u) async {
          opened.add(u);
          return true;
        }),
      )));
      expect(find.byType(Pressable), findsOneWidget);
      expect(_link('O\'Connell 2017'), findsOneWidget);
      await t.tap(find.text('AN-2554 pedometer'));
      await t.tap(find.text('Baevsky 2008'));
      expect(opened, isEmpty);
    });
  });

  testWidgets('Nerd stats shows the training-load citations as links',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Investigate('trimp', data: InvestigateData()),
    ));
    await t.pumpAndSettle();
    expect(_link('Banister 1991'), findsOneWidget);
    expect(_link('Morton 1990'), findsOneWidget);
  });

  testWidgets('Nerd stats shows the steps citations as links', (t) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Investigate('steps', data: InvestigateData()),
    ));
    await t.pumpAndSettle();
    expect(_link('Straczkiewicz 2023'), findsOneWidget);
    expect(_link('O\'Connell 2017'), findsOneWidget);
  });
}
