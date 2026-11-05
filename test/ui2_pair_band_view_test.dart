// First-run "Pair your band": the list, the filter pills, the strap-only
// confirm sheet, the help dialog and the way out. Rendered with fakes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ui2/community_links.dart';
import 'package:openstrap_edge/ui2/pairing/pair_band_view.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart' show PairLinkOpener;

import 'support/pair_ui_support.dart';

class _Links implements PairLinkOpener {
  final opened = <String>[];
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

class _Host implements PairBandHost {
  final void Function(BandEntry) onPick;
  final VoidCallback onStrap;
  _Host(this.onPick, this.onStrap);
  @override
  void pickBand(BandEntry entry) => onPick(entry);
  @override
  void strapOnlyConfirmed() => onStrap();
}

Finder _row(BandEntry e) => find.byKey(ValueKey('band-row-${e.id}'));

void main() {
  group('which devices the first run offers', () {
    test('only the WHOOP bands (DT12)', () {
      final ids = [for (final e in firstRunBandEntries()) e.id];
      expect(ids, ['gen4', 'gen5']);
      // Other bands pair as additional devices from "Add a device"; sensors,
      // scales and the thermometer are never a main device.
      for (final id in ['oura', 'colmi', 'miband234', 'ultrahuman', 'pebble', 'coros', 'garmin',
          'ble_hrs', 'polar_pmd', 'thermometer', 'miscale_bc', 'miscale2']) {
        expect(ids, isNot(contains(id)), reason: id);
      }
    });
  });

  group('PairBandView', () {
    Widget view({
      List<BandEntry>? entries,
      ValueChanged<BandEntry>? onPick,
      VoidCallback? onStrap,
      VoidCallback? onSkip,
      VoidCallback? onDemo,
      String? problem,
      _Links? links,
    }) =>
        PairBandView(
          entries: entries ?? firstRunBandEntries(),
          host: _Host(onPick ?? (_) {}, onStrap ?? () {}),
          onSkip: onSkip,
          onDemoMode: onDemo,
          problem: problem,
          openLink: links ?? _Links(),
        );

    testWidgets('title, subtitle, and one row per device with what it sends', (t) async {
      await pumpPair(t, view(), size: const Size(412, 1600));
      expect(find.text('Pair your band'), findsOneWidget);
      expect(find.text('Pick the one you wear. We will look for it nearby.'), findsOneWidget);
      for (final e in firstRunBandEntries()) {
        expect(_row(e), findsOneWidget, reason: e.id);
      }
      expect(
          find.descendant(
              of: _row(kWhoopGen5),
              matching: find.text(
                  'Sends: sleep, recovery, strain, heart-rate variability, skin temperature')),
          findsOneWidget);
    });

    testWidgets('says plainly that only WHOOP is the main band', (t) async {
      await pumpPair(t, view(), size: const Size(412, 1600));
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsOneWidget);
      expect(find.text('Main band: WHOOP 4.0 or WHOOP 5.0/MG only. Other devices can be added as additional devices.'), findsOneWidget);
    });

    testWidgets('never says what a band would NOT send, nor primary/secondary/tier', (t) async {
      await pumpPair(t, view(), size: const Size(412, 1600));
      for (final w in ['Doesn’t send', 'primary', 'Primary', 'secondary', 'Secondary', 'Tier', 'Experimental']) {
        expect(find.textContaining(w), findsNothing, reason: w);
      }
    });

    testWidgets('pills show only the kinds in the list; Rings narrows it', (t) async {
      // The view works for any list; the first run itself offers WHOOP only.
      final all = [kWhoopGen5, kOura, kColmi, kUltrahuman, kMiBand234, kPebble];
      await pumpPair(t, view(entries: all), size: const Size(412, 1600));
      for (final k in ['All', 'Straps', 'Rings', 'Bands', 'Watches']) {
        expect(find.text(k), findsOneWidget, reason: k);
      }
      expect(find.text('Scales'), findsNothing);
      await t.tap(find.text('Rings'));
      await t.pumpAndSettle();
      expect(_row(kOura), findsOneWidget);
      expect(_row(kColmi), findsOneWidget);
      expect(_row(kUltrahuman), findsOneWidget);
      expect(_row(kWhoopGen5), findsNothing);
      expect(_row(kMiBand234), findsNothing);
      await t.tap(find.text('All'));
      await t.pumpAndSettle();
      expect(_row(kWhoopGen5), findsOneWidget);
    });

    testWidgets('tapping a row picks that device', (t) async {
      final picked = <String>[];
      await pumpPair(t, view(onPick: (e) => picked.add(e.id)), size: const Size(412, 1600));
      await t.tap(_row(kWhoopGen5));
      expect(picked, ['gen5']);
    });

    testWidgets('the strap-only link opens the confirm sheet with the matrix', (t) async {
      await pumpPair(t, view(), size: const Size(412, 1600));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      expect(find.text('Pair a sensor without a band?'), findsOneWidget);
      expect(find.text('A band'), findsOneWidget);
      expect(find.text('This strap'), findsOneWidget);
      expect(find.text('Sleep'), findsWidgets);
      expect(find.text('Pair it as a sensor anyway'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    });

    testWidgets('Go back closes the sheet and pairs nothing', (t) async {
      var confirmed = 0;
      await pumpPair(t, view(onStrap: () => confirmed++), size: const Size(412, 1600));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(find.text('Pair a sensor without a band?'), findsNothing);
      expect(confirmed, 0);
    });

    testWidgets('“Pair it as a sensor anyway” closes the sheet and carries on', (t) async {
      var confirmed = 0;
      await pumpPair(t, view(onStrap: () => confirmed++), size: const Size(412, 1600));
      await t.tap(find.text('I only have a heart-rate strap'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pair it as a sensor anyway'));
      await t.pumpAndSettle();
      expect(find.text('Pair a sensor without a band?'), findsNothing);
      expect(confirmed, 1);
    });

    testWidgets('“I can’t pair my band” opens help; with nothing chosen only Discord', (t) async {
      final links = _Links();
      await pumpPair(t, view(links: links), size: const Size(412, 1600));
      await t.tap(find.text('I can’t pair my band'));
      await t.pumpAndSettle();
      expect(find.text('Need a hand pairing?'), findsOneWidget);
      expect(find.text('See how to put it in pairing mode'), findsNothing);
      await t.tap(find.text('Ask us on Discord'));
      expect(links.opened, [kDiscordUrl]);
    });

    testWidgets('after trying a device, help offers that device’s own page', (t) async {
      final links = _Links();
      await pumpPair(t, view(links: links), size: const Size(412, 1600));
      await t.tap(_row(kWhoopGen5));
      await t.tap(find.text('I can’t pair my band'));
      await t.pumpAndSettle();
      await t.tap(find.text('See how to put it in pairing mode'));
      expect(links.opened, [kWhoopGen5.resetSteps!.officialUrl]);
    });

    testWidgets('Skip for now shows only when there is something to skip', (t) async {
      await pumpPair(t, view(), size: const Size(412, 1600));
      expect(find.text('Skip for now'), findsNothing);
      var skipped = 0;
      await pumpPair(t, view(onSkip: () => skipped++), size: const Size(412, 1600));
      await t.tap(find.text('Skip for now'));
      expect(skipped, 1);
    });

    testWidgets('demo mode is offered only when supplied', (t) async {
      await pumpPair(t, view(onSkip: () {}), size: const Size(412, 1600));
      expect(find.text('Try demo mode'), findsNothing);
      var demo = 0;
      await pumpPair(t, view(onSkip: () {}, onDemo: () => demo++), size: const Size(412, 1600));
      await t.tap(find.text('Try demo mode'));
      expect(demo, 1);
    });

    testWidgets('a problem is said in a card', (t) async {
      await pumpPair(t, view(problem: 'Bluetooth is off.'), size: const Size(412, 1600));
      expect(find.text('Bluetooth is off.'), findsOneWidget);
    });

    testWidgets('German at 2x text on a small phone does not overflow', (t) async {
      await pumpPair(t, view(onSkip: () {}),
          locale: const Locale('de'), textScale: 2, size: const Size(320, 700));
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('Ich habe nur einen Herzfrequenzgurt'), 200);
      await t.ensureVisible(find.text('Ich habe nur einen Herzfrequenzgurt'));
      await t.pumpAndSettle();
      await t.tap(find.text('Ich habe nur einen Herzfrequenzgurt'));
      await t.pumpAndSettle();
      expect(find.text('Sensor ohne Band koppeln?'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
