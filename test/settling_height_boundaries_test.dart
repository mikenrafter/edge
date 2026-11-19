import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/settling_height.dart';

Widget _page(Widget child) => MaterialApp(home: Scaffold(body: Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min,
    children: [SettlingHeight(child: child),
      const SizedBox(key: ValueKey('after'), height: 20)],
  )),
)));

void main() {
  // why: a static sibling can use LayoutBuilder even when another sibling is
  // animating. CLAIM(settling-height-layout-contribution).
  // catches: speculative getDryLayout on every Row child.
  testWidgets('Row uses actual sizes beside a non-dry-layout sibling', (t) async {
    Widget page(double height) => _page(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: SettlingHeight(child: SizedBox(height: height))),
      Expanded(child: LayoutBuilder(builder: (_, _) => const SizedBox(height: 120))),
    ]));
    double top() => t.getTopLeft(find.byKey(const ValueKey('after'))).dy;
    await t.pumpWidget(page(80));
    expect(top(), 120);
    await t.pumpWidget(page(180));
    expect(top(), 120);
    for (var i = 0; i < 15; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(t.takeException(), isNull);
      expect(top(), inInclusiveRange(120, 180));
    }
    await t.pump(const Duration(milliseconds: 10));
    expect(top(), 180);
    await t.pumpWidget(const SizedBox());
  });

  // why: a non-positioned child determines Stack's height; its overlay does
  // not. CLAIM(settling-height-layout-contribution).
  // catches: dropping motion at multi-child Stack and starting another tween.
  testWidgets('Stack follows its moving body and ignores positioned overlays', (t) async {
    Widget page(double height) => _page(Stack(children: [
      SettlingHeight(child: SizedBox(width: 300, height: height)),
      const Positioned(top: 0, left: 0, child: SizedBox(width: 10, height: 400)),
    ]));
    double top() => t.getTopLeft(find.byKey(const ValueKey('after'))).dy;
    await t.pumpWidget(page(80));
    await t.pumpWidget(page(180));
    expect(top(), 80);
    await t.pump(const Duration(milliseconds: 80));
    final body = t.getSize(find.byType(SettlingHeight).last).height;
    expect(top(), body, reason: 'Stack follows the actual child, without a second tween');
    await t.pump(const Duration(milliseconds: 170));
    expect(top(), 180);
    await t.pumpWidget(const SizedBox());
  });

  // why: frame work must depend on registered contribution paths, not an
  // unrelated static card subtree. CLAIM(settling-height-bounded-work).
  // catches: walking all descendants on each animation tick.
  testWidgets('flow does not visit unrelated static branches', (t) async {
    var visits = 0;
    RenderSettlingHeight.debugOnFlow = (nodes, _) => visits += nodes;
    addTearDown(() => RenderSettlingHeight.debugOnFlow = null);
    Widget page(double height) => _page(Column(mainAxisSize: MainAxisSize.min, children: [
      SettlingHeight(child: SizedBox(height: height)),
      Column(children: List.generate(20, (_) => const SizedBox(height: 1))),
    ]));
    await t.pumpWidget(page(80));
    await t.pumpWidget(page(180));
    visits = 0;
    await t.pump(const Duration(milliseconds: 80));
    // Exactly the outer Column and its registered height owner contribute.
    expect(visits, 2);
    await t.pumpWidget(const SizedBox());
  });

  // why: caching a contribution path must not retain a former Column/Stack
  // relationship after a GlobalKey reparent. CLAIM(settling-height-bounded-work).
  // catches: keeping cached routes or baselines through detach/attach.
  testWidgets('registered routes follow reparenting between layouts', (t) async {
    final key = GlobalKey();
    Widget page(bool stack, double height) {
      final body = SettlingHeight(key: key, child: SizedBox(width: 300, height: height));
      return _page(stack
          ? Stack(children: [body, const Positioned(top: 0, child: SizedBox(height: 400))])
          : Column(mainAxisSize: MainAxisSize.min, children: [body]));
    }
    double top() => t.getTopLeft(find.byKey(const ValueKey('after'))).dy;
    await t.pumpWidget(page(false, 80));
    await t.pumpWidget(page(true, 80));
    await t.pumpWidget(page(true, 180));
    expect(top(), 80);
    await t.pump(const Duration(milliseconds: 80));
    expect(top(), t.getSize(find.byKey(key)).height);
    await t.pump(const Duration(milliseconds: 170));
    expect(top(), 180);
    await t.pumpWidget(page(false, 180));
    await t.pumpWidget(page(false, 80));
    await t.pump(const Duration(milliseconds: 80));
    expect(top(), t.getSize(find.byKey(key)).height);
    await t.pump(const Duration(milliseconds: 170));
    expect(top(), 80);
    await t.pumpWidget(const SizedBox());
  });

}
