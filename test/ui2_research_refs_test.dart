// Research citations: the table, and the links drawn from it.
//
// The table may only hold a DOI that already appears in the repo's own
// sources. A reference with no DOI on record stays plain text — a link built
// from a guessed DOI is worse than no link.

import 'dart:io';

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

    test('a reference with no DOI has no URL', () {
      for (final r in kResearchRefs.where((r) => r.doi == null)) {
        expect(r.url, isNull, reason: r.id);
      }
    });

    test('every DOI appears in the repo outside this table', () {
      final text = StringBuffer();
      for (final dir in ['lib', 'docs', 'guides', 'test']) {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          if (f.path.endsWith('lib/ui2/research_refs.dart') ||
              f.path.endsWith('test/ui2_research_refs_test.dart')) {
            continue;
          }
          if (!RegExp(r'\.(dart|md|html|arb)$').hasMatch(f.path)) continue;
          text.write(f.readAsStringSync());
        }
      }
      final all = text.toString();
      for (final r in kResearchRefs.where((r) => r.doi != null)) {
        expect(all, contains(r.doi),
            reason: '${r.id}: DOI ${r.doi} is not in any repo source — '
                'do not add a DOI that has not been seen here');
      }
    });
  });

  group('researchCitation', () {
    testWidgets('each linked citation opens exactly its doi.org URL',
        (t) async {
      for (final r in kResearchRefs.where((r) => r.doi != null)) {
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
        expect(opened, ['https://doi.org/${r.doi}'], reason: r.id);
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
        builder: (c) => researchCitation(c, 'Task Force 1996 · Plews 2013'),
      )));
      expect(_link('Plews 2013'), findsNothing);
      expect(find.byType(Pressable), findsNothing);
      expect(find.text('Task Force 1996 · Plews 2013'), findsOneWidget);
    });

    testWidgets('only the part naming a linked study is tappable',
        (t) async {
      final opened = <String>[];
      await t.pumpWidget(_host(Builder(
        builder: (c) => researchCitation(
            c, 'AN-2554 pedometer · O\'Connell 2017 · Plews 2013',
            open: (u) async {
          opened.add(u);
          return true;
        }),
      )));
      expect(find.byType(Pressable), findsOneWidget);
      expect(_link('O\'Connell 2017'), findsOneWidget);
      await t.tap(find.text('AN-2554 pedometer'));
      await t.tap(find.text('Plews 2013'));
      expect(opened, isEmpty);
    });
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
