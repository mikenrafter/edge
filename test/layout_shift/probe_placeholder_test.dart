// The probe marks loading stand-ins as ElementRole.placeholder, so the appear
// rule can tell a placeholder filled in place (free) from one real card
// replaced by another (charged). Inferred for: a keyed element whose subtree
// holds an InlineLoading, and a widget whose ValueKey<String> starts
// 'skeleton:'. Placeholder wins over the text-based roles (InlineLoading has a
// status Text; a skeleton may hold a label).
// Test surface: 800 x 600 logical. Times are explicit ms offsets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/ui2/inline_loading.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';

import '../support/layout_shift_probe.dart';
import '../support/shift_run.dart' show settleHeight;

Widget _app(List<Widget> children) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            // Stretch: every keyed box is 400 wide, so a card and the loading box
            // it replaces share one rect.
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children),
          ),
        ),
      ),
    );

ElementRole _roleOf(Frame f, String id) =>
    f.elements.singleWhere((e) => e.id == id).role;

void main() {
  testWidgets('F4 pending text keeps its identity when it moves inside a large placeholder', (t) async {
    final probe = ShiftProbe(trackUnkeyed: true);
    Widget page(bool pending) => _app([SizedBox(height: 200,
      child: PendingContent(pending: pending, child: Padding(
        padding: EdgeInsets.only(top: pending ? 0 : 40),
        child: const Align(alignment: Alignment.topLeft, child: Text('Result')))))]);
    await t.pumpWidget(page(true));
    final a = probe.capture(t, atMs: 0);
    await t.pumpWidget(page(false));
    final b = probe.capture(t, atMs: 2500);
    final before = a.elements.singleWhere((e) => e.id.contains('~text|'));
    final after = b.elements.singleWhere((e) => e.id.contains('~text|'));
    expect(before.id, after.id);
    expect(before.rect.top, isNot(after.rect.top));
  });

  // WHY: the stable keyed envelope survives a read, but its painted placeholder
  // disappears. Dropping the coincident placeholder box falsely charges a fill.
  testWidgets('paint placeholder fills a persistent keyed envelope', (t) async {
    final probe = ShiftProbe(trackUnkeyed: true);
    Widget slot(bool pending) => SizedBox(key: const ValueKey('envelope'),
      height: 200, child: PendingContent(pending: pending,
        child: const Align(alignment: Alignment.topLeft, child: Text('Recorded result'))));
    await t.pumpWidget(_app([slot(true)]));
    probe.capture(t, atMs: 0);
    probe.interactions.add(const Interaction(0, 'open'));
    await t.pumpWidget(_app([slot(false)]));
    probe.capture(t, atMs: 2500);
    final report = score(probe.scenario(const ShiftRect(0, 0, 800, 600)),
      ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0));
    expect(report.findings.where((f) => f.rule == 'appear'), isEmpty);
  });

  // WHY: recognizing paint placeholders must not forgive an undersized slot.
  // Catches: charging every arrival as a free fill regardless of geometry.
  testWidgets('an undersized paint placeholder still moves the footer', (t) async {
    final probe = ShiftProbe(trackUnkeyed: true);
    Widget slot(bool pending) => PendingContent(pending: pending,
      child: SizedBox(height: pending ? 40 : 200, child: const Text('Result')));
    const footer = SizedBox(key: ValueKey('footer'), height: 60);
    await t.pumpWidget(_app([slot(true), footer]));
    probe.capture(t, atMs: 0);
    probe.interactions.add(const Interaction(0, 'open'));
    await t.pumpWidget(_app([slot(false), footer]));
    await settleHeight(t);
    probe.capture(t, atMs: 2500);
    final report = score(probe.scenario(const ShiftRect(0, 0, 800, 600)),
      ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0));
    expect(report.findings.where((f) => f.elementId == 'footer' && f.rule == 'shift'), isNotEmpty);
    expect(report.total, greaterThan(0.016));
  });

  testWidgets('a keyed element whose subtree is an InlineLoading', (t) async {
    await t.pumpWidget(_app(const [
      SizedBox(
        key: ValueKey('rings'),
        child: InlineLoading(status: 'Reading last night', height: 200),
      ),
    ]));
    final f = ShiftProbe().capture(t, atMs: 0);
    expect(_roleOf(f, 'rings'), ElementRole.placeholder);
  });

  testWidgets('a keyed InlineLoading itself', (t) async {
    await t.pumpWidget(_app(const [
      InlineLoading(
          key: ValueKey('loading'),
          status: 'Reading your heart rate days',
          detail: 'Calculating · day 3 of 12'),
    ]));
    final f = ShiftProbe().capture(t, atMs: 0);
    expect(_roleOf(f, 'loading'), ElementRole.placeholder);
  });

  testWidgets("a ValueKey('skeleton:...') widget, even with a label in it",
      (t) async {
    await t.pumpWidget(_app(const [
      SizedBox(key: ValueKey('skeleton:rings'), height: 120),
      SizedBox(
        key: ValueKey('skeleton:sleep'),
        height: 80,
        child: Text('Sleep'),
      ),
    ]));
    final f = ShiftProbe().capture(t, atMs: 0);
    expect(_roleOf(f, 'skeleton:rings'), ElementRole.placeholder);
    expect(_roleOf(f, 'skeleton:sleep'), ElementRole.placeholder);
  });

  testWidgets('real content is not a placeholder', (t) async {
    await t.pumpWidget(_app(const [
      SizedBox(key: ValueKey('card:rings'), height: 120, child: Text('Rings')),
      SizedBox(key: ValueKey('gap'), height: 40),
      // 'skeleton' must be a key PREFIX, not anywhere in the id.
      SizedBox(key: ValueKey('card:skeleton:x'), height: 40),
    ]));
    final f = ShiftProbe().capture(t, atMs: 0);
    expect(_roleOf(f, 'card:rings'), ElementRole.paragraph);
    expect(_roleOf(f, 'gap'), ElementRole.other);
    expect(_roleOf(f, 'card:skeleton:x'), ElementRole.other);
  });

  testWidgets('end to end: InlineLoading filled in place by its card is free',
      (t) async {
    final probe = ShiftProbe();
    const loading = SizedBox(
      key: ValueKey('loading:rings'),
      child: InlineLoading(status: 'Reading last night', height: 200),
    );
    const card = SizedBox(key: ValueKey('card:rings'), height: 200);
    const below = SizedBox(key: ValueKey('below'), height: 60);
    await t.pumpWidget(_app(const [loading, below]));
    probe.interactions.add(const Interaction(0, 'tap'));
    probe.capture(t, atMs: 16);
    await t.pumpWidget(_app(const [card, below]));
    probe.capture(t, atMs: 3000);
    probe.capture(t, atMs: 3100);
    // Guard against a vacuous pass: the card really lands on the loading box.
    final was = probe.frames.first.elements
        .singleWhere((e) => e.id == 'loading:rings')
        .rect;
    final now = probe.frames[1].elements
        .singleWhere((e) => e.id == 'card:rings')
        .rect;
    expect([now.left, now.top, now.width, now.height],
        [was.left, was.top, was.width, was.height]);
    expect(now.width * now.height, 400 * 200);
    final r = score(probe.scenario(const ShiftRect(0, 0, 800, 600)),
        ShiftPolicy.standard);
    expect(
        r.findings.where((f) => f.rule == 'appear' && f.score > 0), isEmpty);
    expect(probe.frames.first.elements.map((e) => e.role),
        contains(ElementRole.placeholder));
  });
}
