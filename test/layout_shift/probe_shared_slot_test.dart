// SharedSlot marks one element as "the same thing" on every screen it
// appears on, by putting ValueKey('shared:<id>') on its child. The probe
// already tracks ValueKey<String> ids, so a SharedSlot is captured under
// 'shared:<id>' with its child's rect, and compareLayouts can match it across
// screens. Kept apart from probe_placeholder_test.dart: SharedSlot
// (lib/ui2/shared_slot.dart) does not exist yet, so this file is compile-red.
// Test surface: 800 x 600 logical.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/ui2/shared_slot.dart';

import '../support/layout_shift_probe.dart';

Widget _app(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );

void main() {
  testWidgets("SharedSlot('avatar') is captured as 'shared:avatar'",
      (t) async {
    await t.pumpWidget(_app(const SharedSlot('avatar',
        child: SizedBox(width: 40, height: 40))));
    expect(find.byKey(const ValueKey('shared:avatar')), findsOneWidget);
    final f = ShiftProbe().capture(t, atMs: 0);
    final e = f.elements.singleWhere((e) => e.id == 'shared:avatar');
    expect([e.rect.left, e.rect.top, e.rect.width, e.rect.height],
        [16, 16, 40, 40]);
  });

  testWidgets('a tappable shared avatar is a control', (t) async {
    await t.pumpWidget(_app(SharedSlot('avatar',
        child: Semantics(
          button: true,
          child: GestureDetector(
              onTap: () {}, child: const SizedBox(width: 40, height: 40)),
        ))));
    final f = ShiftProbe().capture(t, atMs: 0);
    expect(f.elements.singleWhere((e) => e.id == 'shared:avatar').role,
        ElementRole.control);
  });

  testWidgets('the same id on two screens matches across them', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(_app(const SharedSlot('avatar',
        child: SizedBox(width: 40, height: 40))));
    final a = probe.capture(t, atMs: 0);
    await t.pumpWidget(_app(const Padding(
        padding: EdgeInsets.only(top: 24),
        child: SharedSlot('avatar', child: SizedBox(width: 40, height: 40)))));
    final b = probe.capture(t, atMs: 0);
    final r = compareLayouts(a, b, ShiftPolicy.standard,
        viewport: const ShiftRect(0, 0, 800, 600),
        only: (id) => id.startsWith('shared:'));
    expect(r.findings.map((f) => f.elementId), contains('shared:avatar'));
  });
}
