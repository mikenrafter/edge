// Home's "Natural Wake is buzzing" card: there only while the repeat runs, and
// its button is an explicit "I'm up" that leaves the native alarm armed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/natural_wake_card.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

void main() {
  testWidgets('shown only while buzzing; "I\'m up" acknowledges without '
      'cancelling the native alarm', (t) async {
    final acks = <bool>[];
    final wake = WakeController(
      schedule: () => const [],
      saveEntry: (_) async {},
      loadUpgradeState: () async => throw UnimplementedError(),
      saveUpgradeState: (_) async {},
      acknowledgeWake: (cancelNative) async {
        acks.add(cancelNative);
        return const WakeAckOutcome(
            nativeCancelRequested: false,
            nativeCancelled: false,
            fallbackArmed: true);
      },
      traceFor: (_) async => const [],
    );
    addTearDown(wake.dispose);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: NaturalWakeBuzzingCard(wake: wake)),
    ));
    expect(find.text('Natural Wake is buzzing'), findsNothing);

    wake.noteNaturalRepeat(true);
    await t.pump();
    expect(find.text('Natural Wake is buzzing'), findsOneWidget);
    expect(find.text('or double-tap the band'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('natural-wake-im-up')));
    await t.pump();
    expect(acks, [false]);

    wake.noteNaturalRepeat(false);
    await t.pump();
    expect(find.text('Natural Wake is buzzing'), findsNothing);
  });
}
