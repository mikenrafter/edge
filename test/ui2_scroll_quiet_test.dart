import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/scroll_quiet.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// Owner m348: "a debounce of 200 milliseconds across the board from a scroll".
// WHY / CLAIM(scroll-tap-quiet): a tap whose finger lands within 200 ms of a
// user scroll's last movement is dropped, on every shared tap widget; a tap at
// 250 ms works; a screen reader's activation always works; a programmatic
// scroll never starts the window. CATCHES: a page-local guard, a window that is
// too long or too short, a gate on the semantics action, a pin glide or row
// reveal that counts as a finger.
void main() {
  late ScrollController controller;
  var tab = 0, kept = 0;

  Future<void> mount(WidgetTester t, {bool scoped = true}) async {
    tab = 0;
    kept = 0;
    controller = ScrollController();
    addTearDown(controller.dispose);
    Widget body = Column(children: [
      StatefulBuilder(builder: (c, set) => SubTabs(const ['Pending', 'Saved'], tab,
          (i) => set(() => tab = i))),
      BigButton('Keep', dense: true, onTap: () => kept++),
      Expanded(child: ListView(key: const ValueKey('list'), controller: controller,
          children: [for (var i = 0; i < 60; i++) SizedBox(height: 100, child: Text('row $i'))])),
    ]);
    if (scoped) body = ScrollQuietListener(child: body);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: body)));
  }

  // 16 ms frames until the fling is over: pumpAndSettle can burn a further 100 ms
  // frame past the last movement, which would eat into the window under test.
  Future<void> settleFrames(WidgetTester t) async {
    for (var i = 0; i < 600 && (i == 0 || t.binding.hasScheduledFrame); i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> flingAndSettle(WidgetTester t) async {
    await t.fling(find.byKey(const ValueKey('list')), const Offset(0, -300), 3000);
    await settleFrames(t);
  }

  testWidgets('a tab and a Keep button ignore a tap 150 ms after a fling, accept one at 250 ms', (t) async {
    await mount(t);
    await flingAndSettle(t);
    await t.pump(const Duration(milliseconds: 150));
    await t.tap(find.text('Saved'));
    await t.tap(find.text('Keep'));
    await t.pump(const Duration(milliseconds: 20));
    expect((tab, kept), (0, 0), reason: 'within 200 ms of the fling');

    await flingAndSettle(t);
    await t.pump(const Duration(milliseconds: 250));
    await t.tap(find.text('Saved'));
    await t.tap(find.text('Keep'));
    await t.pump(const Duration(milliseconds: 20));
    expect((tab, kept), (1, 1), reason: 'after the quiet window');
  });

  testWidgets('a tap while the page is still flinging is dropped', (t) async {
    await mount(t);
    await t.fling(find.byKey(const ValueKey('list')), const Offset(0, -300), 4000);
    await t.pump(const Duration(milliseconds: 80));
    await t.tap(find.text('Keep'));
    await t.pump(const Duration(milliseconds: 20));
    expect(kept, 0);
    await t.pumpAndSettle();
  });

  testWidgets('screen-reader activation right after a scroll is accepted', (t) async {
    final handle = t.ensureSemantics();
    await mount(t);
    await flingAndSettle(t);
    await t.pump(const Duration(milliseconds: 50));
    for (final label in ['Keep', 'Saved']) {
      t.binding.pipelineOwner.semanticsOwner!
          .performAction(t.getSemantics(find.text(label)).id, SemanticsAction.tap);
    }
    await t.pump(const Duration(milliseconds: 20));
    expect((tab, kept), (1, 1));
    handle.dispose();
  });

  testWidgets('a programmatic scroll never starts the quiet window', (t) async {
    await mount(t);
    controller.animateTo(400, duration: const Duration(milliseconds: 120), curve: Curves.linear);
    await t.pumpAndSettle();
    await t.tap(find.text('Keep'));
    await t.pump(const Duration(milliseconds: 20));
    expect(kept, 1);
    controller.jumpTo(0);
    await t.pump();
    await t.tap(find.text('Saved'));
    await t.pump(const Duration(milliseconds: 20));
    expect(tab, 1);
  });

  testWidgets('without a ScrollQuietListener nothing is gated', (t) async {
    await mount(t, scoped: false);
    await flingAndSettle(t);
    await t.tap(find.text('Keep'));
    await t.pump(const Duration(milliseconds: 20));
    expect(kept, 1);
  });
}
