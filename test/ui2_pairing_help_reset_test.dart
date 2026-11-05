// ignore_for_file: depend_on_referenced_packages
// The "I can't pair my band" help dialog and the reset-steps view, plus the
// pairing screen's failure states that show them. Rendered, with fake link
// openers: no browser, no BLE.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ui2/community_links.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/pair_help.dart';
import 'package:openstrap_edge/ui2/pairing/reset_steps_view.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/pair_ui_support.dart';

class _Links implements PairLinkOpener {
  final opened = <String>[];
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

class _FakeLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final calls = <(String, PreferredLaunchMode)>[];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls.add((url, options.mode));
    return true;
  }
}

Widget _scroll(Widget w) => Scaffold(
    body: SingleChildScrollView(
        padding: const EdgeInsets.all(16), child: w));

void main() {
  group('help dialog (H1)', () {
    testWidgets('a device with an official page offers it, Discord, and Close',
        (t) async {
      final links = _Links();
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kWhoopGen5, openLink: links)));
      expect(find.text('Need a hand pairing?'), findsOneWidget);
      expect(find.text('See how to put it in pairing mode'), findsOneWidget);
      expect(find.text('Opens the maker’s help page in your browser'), findsOneWidget);
      expect(find.text('Ask us on Discord'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('the official choice opens that device’s own page', (t) async {
      final links = _Links();
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kWhoopGen5, openLink: links)));
      await t.tap(find.text('See how to put it in pairing mode'));
      expect(links.opened, [kWhoopGen5.resetSteps!.officialUrl]);
    });

    testWidgets('an unverified device’s choice opens its maker page too', (t) async {
      final links = _Links();
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kColmi, openLink: links)));
      await t.tap(find.text('See how to put it in pairing mode'));
      expect(links.opened, [kColmi.resetSteps!.officialUrl]);
    });

    testWidgets('the Discord choice opens the community link', (t) async {
      final links = _Links();
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kWhoopGen5, openLink: links)));
      await t.tap(find.text('Ask us on Discord'));
      expect(links.opened, [kDiscordUrl]);
    });

    testWidgets('a device with no official site gets Discord only', (t) async {
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kBleHrs, openLink: _Links())));
      expect(find.text('See how to put it in pairing mode'), findsNothing);
      expect(find.text('Ask us on Discord'), findsOneWidget);
    });

    testWidgets('no device chosen yet: Discord only', (t) async {
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: null, openLink: _Links())));
      expect(find.text('See how to put it in pairing mode'), findsNothing);
      expect(find.text('Ask us on Discord'), findsOneWidget);
    });

    testWidgets('Close dismisses the dialog and opens nothing', (t) async {
      final links = _Links();
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: Center(
                      child: TextButton(
                          onPressed: () => showPairHelpDialog(c,
                              entry: kWhoopGen5, openLink: links),
                          child: const Text('open'))))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Need a hand pairing?'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text('Need a hand pairing?'), findsNothing);
      expect(links.opened, isEmpty);
    });

    testWidgets('by default links leave the app: external application mode', (t) async {
      final fake = _FakeLauncher();
      final before = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      addTearDown(() => UrlLauncherPlatform.instance = before);
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kWhoopGen5)));
      await t.tap(find.text('Ask us on Discord'));
      await t.pump();
      await t.tap(find.text('See how to put it in pairing mode'));
      await t.pump();
      expect(fake.calls, [
        (kDiscordUrl, PreferredLaunchMode.externalApplication),
        (kWhoopGen5.resetSteps!.officialUrl!, PreferredLaunchMode.externalApplication),
      ]);
    });

    testWidgets('German copy fits at 2x text', (t) async {
      await pumpPair(t, Scaffold(body: PairHelpDialog(entry: kWhoopGen5, openLink: _Links())),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      expect(t.takeException(), isNull);
      expect(find.text('Schließen'), findsOneWidget);
    });
  });

  group('reset steps view', () {
    testWidgets('WHOOP 5 shows its own four steps, no “not checked” note, no maker row',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen5, openLink: _Links())));
      expect(find.text('To reset it'), findsOneWidget);
      expect(find.textContaining('Take the band off your wrist'), findsOneWidget);
      expect(find.textContaining('tap the top firmly'), findsOneWidget);
      expect(find.textContaining('force-quit it'), findsOneWidget);
      expect(find.text('Come back here and try again.'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-general-note')), findsNothing);
      expect(find.text('Open the maker’s help page'), findsNothing);
    });

    testWidgets('a WHOOP says pairing here disconnects it from the WHOOP app', (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen5)));
      expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen4)));
      expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
    });

    testWidgets('an unverified device: orange note, three general steps, maker link row',
        (t) async {
      final links = _Links();
      await pumpPair(t, _scroll(ResetStepsView(entry: kColmi, openLink: links)));
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.textContaining('We haven’t checked the exact steps'), findsOneWidget);
      expect(find.text('Open the maker’s app and remove this device from it.'), findsOneWidget);
      expect(find.textContaining('choose Forget'), findsOneWidget);
      expect(find.textContaining('Restart the device'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleAlert), findsOneWidget);
      final host = Uri.parse(kColmi.resetSteps!.officialUrl!).host;
      expect(find.text('$host · opens in your browser'), findsOneWidget);
      await t.tap(find.text('Open the maker’s help page'));
      expect(links.opened, [kColmi.resetSteps!.officialUrl]);
      // Not a WHOOP: no takeover line.
      expect(find.byKey(const ValueKey('reset-whoop-takeover')), findsNothing);
    });

    testWidgets('WHOOP 4 is unverified: general steps, note, maker row, and the takeover line',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kWhoopGen4)));
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-whoop-takeover')), findsOneWidget);
    });

    testWidgets('a device with no official site: general steps, no maker row, no orange alert',
        (t) async {
      await pumpPair(t, _scroll(ResetStepsView(entry: kThermometer)));
      expect(find.text('Open the maker’s app and remove this device from it.'), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsNothing);
      expect(find.byIcon(LucideIcons.circleAlert), findsNothing);
      // Still says the steps are general.
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
    });

    testWidgets('every registry entry renders, at 2x German text, without overflow', (t) async {
      for (final e in kBandRegistry) {
        await pumpPair(t, _scroll(ResetStepsView(entry: e)),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
        expect(t.takeException(), isNull, reason: e.id);
        expect(find.text('So setzt du es zurück'), findsOneWidget, reason: e.id);
      }
    });
  });

  group('pairing screen: when pairing could not finish', () {
    Widget view(PairPhase phase,
            {BandEntry? entry, VoidCallback? onPair, VoidCallback? onPick, _Links? links}) =>
        PairingView(
          phase: phase,
          onPair: onPair ?? () {},
          resetEntry: entry,
          onPickDifferent: onPick,
          openLink: (links ?? _Links()),
        );

    for (final phase in [PairPhase.notFound, PairPhase.bondRefused, PairPhase.failed]) {
      testWidgets('${phase.name}: the entry’s reset steps and three ways forward', (t) async {
        var tried = 0, picked = 0;
        await pumpPair(
            t,
            view(phase,
                entry: kWhoopGen5, onPair: () => tried++, onPick: () => picked++),
            size: const Size(412, 1400));
        expect(find.text('Your band is paired somewhere else'), findsOneWidget);
        expect(find.textContaining('We couldn’t finish pairing WHOOP 5.'), findsOneWidget);
        expect(find.textContaining('tap the top firmly'), findsOneWidget);
        expect(find.text('Pairing here disconnects it from the WHOOP app.'), findsOneWidget);
        await t.tap(find.text('Try again'));
        expect(tried, 1);
        await t.tap(find.text('Pick a different band'));
        expect(picked, 1);
        expect(find.text('I can’t pair my band'), findsOneWidget);
      });
    }

    testWidgets('“I can’t pair my band” opens the help dialog for this device', (t) async {
      final links = _Links();
      await pumpPair(t, view(PairPhase.notFound, entry: kWhoopGen5, links: links),
          size: const Size(412, 1400));
      await t.tap(find.text('I can’t pair my band'));
      await t.pumpAndSettle();
      expect(find.text('Need a hand pairing?'), findsOneWidget);
      await t.tap(find.text('See how to put it in pairing mode'));
      expect(links.opened, [kWhoopGen5.resetSteps!.officialUrl]);
    });

    testWidgets('an unverified ring: ring wording, orange note, maker row', (t) async {
      await pumpPair(t, view(PairPhase.bondRefused, entry: kColmi), size: const Size(412, 1400));
      expect(find.text('Your ring is paired somewhere else'), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-general-note')), findsOneWidget);
      expect(find.text('Open the maker’s help page'), findsOneWidget);
    });

    testWidgets('without an entry the screen is unchanged: no reset steps, no help button', (t) async {
      await pumpPair(t, view(PairPhase.notFound), size: const Size(412, 1400));
      expect(find.text('To reset it'), findsNothing);
      expect(find.text('I can’t pair my band'), findsNothing);
      expect(find.text('No band in range'), findsOneWidget);
    });

    for (final phase in [PairPhase.idle, PairPhase.cancelled, PairPhase.paired]) {
      testWidgets('${phase.name} never shows reset steps', (t) async {
        await pumpPair(t, view(phase, entry: kWhoopGen5), size: const Size(412, 1400));
        expect(find.text('To reset it'), findsNothing);
      });
    }

    testWidgets('German at 2x text does not overflow', (t) async {
      await pumpPair(t, view(PairPhase.notFound, entry: kColmi),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 1800));
      expect(t.takeException(), isNull);
    });
  });
}
