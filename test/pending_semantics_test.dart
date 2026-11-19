// Proves CLAIM(pending-semantics): only user-started settlement announces
// completion; background reads stay quiet, and pending template values stay hidden.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';

Widget page(bool pending) => MaterialApp(home: PendingSectionScope(
  pendingSectionName: 'Signals',
  child: PendingContent(pending: pending, child: const Text('A recorded value')),
));
Finder liveRegions() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.liveRegion == true,
);

void main() {
  testWidgets('background load names its section and settles quietly', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(page(true));
    expect(find.bySemanticsLabel('Loading, Signals'), findsOneWidget);
    expect(find.bySemanticsLabel('A recorded value'), findsNothing);
    await t.pumpWidget(page(false));
    expect(find.bySemanticsLabel('A recorded value'), findsOneWidget);
    expect(liveRegions(), findsNothing);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });
  // Catches: announcing every background update, or never announcing a user read.
  testWidgets('a user-started load announces completion for one build', (t) async {
    final semantics = t.ensureSemantics();
    await PendingUserAction.run(() => t.pumpWidget(page(true)));
    expect(liveRegions(), findsNothing);
    await t.pumpWidget(page(false));
    expect(find.bySemanticsLabel('Loaded, Signals'), findsOneWidget);
    expect(liveRegions(), findsOneWidget);
    await t.pump();
    expect(liveRegions(), findsNothing);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });
}
