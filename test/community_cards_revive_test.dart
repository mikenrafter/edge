// Developer setting "Revive community cards".
//
// In developer mode the Discord and Sponsor cards ignore a stored dismissal and
// the 14-day cooldown (someone testing the app must be able to reach them on
// every build). That stays the DEFAULT. The new setting lets a developer turn
// it off, and then developer mode behaves exactly like a normal install here:
// a dismissed card stays gone, a recently shown one waits out its cooldown.
//
//   dev ON  + setting ON  (default) -> dismissed card shown        (unchanged)
//   dev ON  + setting OFF           -> dismissal + cooldown honoured
//   dev OFF                         -> the setting changes nothing
//   a dismissal tapped THIS launch  -> hidden in every case        (unchanged)
//
// Time is injected (`CommunityNudge.debugNowMs`): no test reads the clock.
// The settings row exists only in developer mode, with the exact label
// "Revive community cards", and flips the pref through the real screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/settings_sections.dart';

const _day = 24 * 60 * 60 * 1000;
// A fixed instant: 2026-10-08 12:00:00 UTC.
const _t0 = 1791460800000;

final _discord = find.text('OpenStrap Discord');
final _donate = find.text('Support OpenStrap');
const _label = 'Revive community cards';

Future<void> _seed(WidgetTester t, Map<String, Object> values) async {
  await t.runAsync(() async {
    await Prefs.ensureLoaded();
    final sp = await SharedPreferences.getInstance();
    await sp.clear();
    for (final e in values.entries) {
      final v = e.value;
      if (v is bool) await sp.setBool(e.key, v);
      if (v is int) await sp.setInt(e.key, v);
    }
    CommunityNudge.debugResetSession();
  });
}

Future<void> _pumpNudge(WidgetTester t, {required bool dev}) async {
  await t.pumpWidget(Provider<Capabilities>.value(
    value: Capabilities(CapabilityInputs.detached(devMode: dev)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: SingleChildScrollView(child: CommunityNudge())),
    ),
  ));
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() => CommunityNudge.debugNowMs = _t0);
  tearDown(() => CommunityNudge.debugNowMs = null);

  group('the preference', () {
    testWidgets('defaults to ON, and the key is dev.revive_community_cards',
        (t) async {
      await _seed(t, {});
      expect(Prefs.reviveCommunityCards, 'dev.revive_community_cards');
      expect(Prefs.reviveCommunityCardsOn, isTrue);
    });

    testWidgets('reads what was stored', (t) async {
      await _seed(t, {Prefs.reviveCommunityCards: false});
      expect(Prefs.reviveCommunityCardsOn, isFalse);
      await _seed(t, {Prefs.reviveCommunityCards: true});
      expect(Prefs.reviveCommunityCardsOn, isTrue);
    });
  });

  group('developer mode, setting ON (the default): unchanged', () {
    testWidgets('a permanently dismissed card is shown', (t) async {
      await _seed(t, {
        'nudge.discord.dismissed': true,
        'nudge.donate.dismissed': true,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
      expect(_donate, findsOneWidget);
    });

    testWidgets('a card shown a minute ago (inside the cooldown) is shown',
        (t) async {
      await _seed(t, {
        'nudge.discord.last_shown_ms': _t0 - 60 * 1000,
        'nudge.donate.last_shown_ms': _t0 - 60 * 1000,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
      expect(_donate, findsOneWidget);
    });

    testWidgets('an explicit ON behaves like the default', (t) async {
      await _seed(t, {
        Prefs.reviveCommunityCards: true,
        'nudge.discord.dismissed': true,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
    });
  });

  group('developer mode, setting OFF: a normal install', () {
    testWidgets('a permanently dismissed card stays hidden; the other shows',
        (t) async {
      await _seed(t, {
        Prefs.reviveCommunityCards: false,
        'nudge.discord.dismissed': true,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsNothing);
      expect(_donate, findsOneWidget, reason: 'only Discord was dismissed');
    });

    testWidgets('inside the 14-day cooldown the card is hidden', (t) async {
      await _seed(t, {
        Prefs.reviveCommunityCards: false,
        'nudge.discord.last_shown_ms': _t0 - 13 * _day,
        'nudge.donate.last_shown_ms': _t0 - 1 * _day,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsNothing);
      expect(_donate, findsNothing);
    });

    testWidgets('past the cooldown the card comes back', (t) async {
      await _seed(t, {
        Prefs.reviveCommunityCards: false,
        'nudge.discord.last_shown_ms': _t0 - 15 * _day,
        'nudge.donate.last_shown_ms': _t0 - 15 * _day,
      });
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
      expect(_donate, findsOneWidget);
    });

    testWidgets('a fresh install still shows both, and starts the cooldown',
        (t) async {
      await _seed(t, {Prefs.reviveCommunityCards: false});
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
      expect(_donate, findsOneWidget);
      expect(Prefs.getInt('nudge.discord.last_shown_ms', 0), _t0,
          reason: 'stamped with the injected clock, not the real one');
    });

    testWidgets('showing it once and mounting again within the cooldown '
        'hides it, as for a normal reader', (t) async {
      await _seed(t, {Prefs.reviveCommunityCards: false});
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
      CommunityNudge.debugNowMs = _t0 + 2 * _day;
      await t.pumpWidget(const SizedBox());
      await _pumpNudge(t, dev: true);
      expect(_discord, findsNothing);
      CommunityNudge.debugNowMs = _t0 + 15 * _day;
      await t.pumpWidget(const SizedBox());
      await _pumpNudge(t, dev: true);
      expect(_discord, findsOneWidget);
    });
  });

  group('developer mode off: the setting is irrelevant', () {
    for (final on in [true, false]) {
      testWidgets('setting ${on ? 'ON' : 'OFF'}: dismissal and cooldown '
          'are honoured', (t) async {
        await _seed(t, {
          Prefs.reviveCommunityCards: on,
          'nudge.discord.dismissed': true,
          'nudge.donate.last_shown_ms': _t0 - 1 * _day,
        });
        await _pumpNudge(t, dev: false);
        expect(_discord, findsNothing);
        expect(_donate, findsNothing);
      });

      testWidgets('setting ${on ? 'ON' : 'OFF'}: a fresh install shows both',
          (t) async {
        await _seed(t, {Prefs.reviveCommunityCards: on});
        await _pumpNudge(t, dev: false);
        expect(_discord, findsOneWidget);
        expect(_donate, findsOneWidget);
      });
    }
  });

  group('a dismissal tapped this launch still hides the card', () {
    for (final on in [true, false]) {
      testWidgets('setting ${on ? 'ON' : 'OFF'}, developer mode', (t) async {
        await _seed(t, {Prefs.reviveCommunityCards: on});
        await _pumpNudge(t, dev: true);
        expect(_discord, findsOneWidget);
        await t.tap(find.text("Don't show this again").first);
        await t.pump();
        expect(_discord, findsNothing);
        // A remount (Home changes shape during a recalculation) keeps it away.
        await t.pumpWidget(const SizedBox());
        await _pumpNudge(t, dev: true);
        expect(_discord, findsNothing);
      });
    }
  });

  group('the settings row', () {
    Future<void> pumpView(WidgetTester t,
        {required bool dev, bool revive = true, VoidCallback? onToggle}) =>
        pumpTall(
            t,
            MoreSettingsView(
              devMode: dev,
              version: '1',
              reviveCommunityCards: revive,
              onToggleReviveCommunityCards: onToggle,
            ));

    Finder row() => find.byWidgetPredicate(
        (w) => w is SetRow && w.title == _label,
        description: 'SetRow "$_label"');

    testWidgets('exists in developer mode, in the Developer group, with the '
        'exact label', (t) async {
      await pumpView(t, dev: true);
      expect(find.text(_label), findsOneWidget);
      expect(
          find.descendant(of: section('Developer'), matching: row()),
          findsOneWidget);
    });

    testWidgets('does not exist outside developer mode', (t) async {
      await pumpView(t, dev: false);
      expect(find.text(_label), findsNothing);
      expect(row(), findsNothing);
    });

    testWidgets('shows On when ON and Off when OFF; a tap calls back',
        (t) async {
      var taps = 0;
      await pumpView(t, dev: true, revive: true, onToggle: () => taps++);
      expect(t.widget<SetRow>(row()).value, 'On');
      await t.tap(find.text(_label));
      await t.pump();
      expect(taps, 1);
      await pumpView(t, dev: true, revive: false, onToggle: () => taps++);
      expect(t.widget<SetRow>(row()).value, 'Off');
    });

    testWidgets('on the real screen a tap flips the stored preference and '
        'the row follows', (t) async {
      await _seed(t, {});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      t.view.physicalSize = const Size(1170, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider(
              create: (_) =>
                  ThemeController.seed(AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
          Provider<Capabilities>.value(
              value: Capabilities(CapabilityInputs.detached(devMode: true))),
        ],
        child: MaterialApp(
            theme: buildTheme(Brightness.light), home: const MoreSettings()),
      ));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(row(), findsOneWidget);
      expect(Prefs.reviveCommunityCardsOn, isTrue);
      expect(t.widget<SetRow>(row()).value, 'On');

      await t.tap(find.text(_label));
      await t.pump();
      expect(Prefs.reviveCommunityCardsOn, isFalse);
      expect(t.widget<SetRow>(row()).value, 'Off');

      await t.tap(find.text(_label));
      await t.pump();
      expect(Prefs.reviveCommunityCardsOn, isTrue);
      expect(t.widget<SetRow>(row()).value, 'On');
    });
  });
}
