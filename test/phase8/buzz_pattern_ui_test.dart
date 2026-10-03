// 8D — the "Buzz pattern" controls and the "Tap your pattern" recorder sheet.
// See test/phase8/CONTRACTS.md §8D (UI).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

NotificationPrefs _withBand(String id) {
  const p = NotificationPrefs();
  return p.withAlertRule({
    ...p.alertRule(id).toJson(),
    'enabled': true,
    'destinations': AlertRule.band,
  });
}

/// A sequence with the extended opset on. Through Function.apply so this file
/// still compiles before BuzzSequence has the field.
BuzzSequence _ext(List<int> offsets) =>
    Function.apply(BuzzSequence.new, [offsets], {#extended: true})
        as BuzzSequence;

bool _extendedOf(BuzzSequence s) => (s as dynamic).extended as bool;

const _extKey = ValueKey('buzz-extended');

bool _switchOn(WidgetTester t) => t.widget<Switch>(find.byKey(_extKey)).value;

/// Two quick taps 400 ms apart, then past the 2 s idle that ends the take.
Future<void> _takeTwoTaps(WidgetTester t) async {
  final button = find.text('Tap your pattern');
  await t.tap(button);
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(button);
  await t.pump(const Duration(milliseconds: 2100));
  await t.pumpAndSettle();
}

void main() {
  group('Notifications: a Buzz pattern control per notification type', () {
    testWidgets('a band-delivered rule has one; tapping it names the rule',
        (t) async {
      final picked = <String>[];
      await _pump(
          t,
          NotificationSettingsView(
            prefs: _withBand('water'),
            relaySupported: true,
            onBuzzPattern: picked.add,
          ));
      final control = find.byKey(const ValueKey('buzz-pattern:water'));
      expect(control, findsOneWidget);
      expect(find.descendant(of: control, matching: find.text('Buzz pattern')),
          findsOneWidget);
      await t.tap(control);
      expect(picked, ['water']);
    });

    testWidgets('every rule row that can reach the band shows the control',
        (t) async {
      await _pump(
          t,
          NotificationSettingsView(
            prefs: _withBand('meds'),
            relaySupported: true,
            onBuzzPattern: (_) {},
          ));
      for (final id in ['water', 'meds', 'movement']) {
        expect(find.byKey(ValueKey('buzz-pattern:$id')), findsOneWidget,
            reason: '$id can be delivered to the band');
      }
    });

    testWidgets('band not selected: the control is shown but does nothing',
        (t) async {
      final picked = <String>[];
      await _pump(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(),
            relaySupported: true,
            onBuzzPattern: picked.add,
          ));
      final control = find.byKey(const ValueKey('buzz-pattern:water'));
      expect(control, findsOneWidget, reason: '8K: disabled, not hidden');
      await t.tap(control, warnIfMissed: false);
      expect(picked, isEmpty);
    });
  });

  group('Band notifications: per channel and per app', () {
    testWidgets('App notifications channel and each app have a control',
        (t) async {
      final apps = <String>[];
      final channels = <String>[];
      await _pump(
          t,
          BandNotificationsView(
            enabled: true,
            granted: true,
            apps: const [
              RelayApp('com.whatsapp', on: true),
              RelayApp('org.telegram.messenger', on: true),
            ],
            onAppBuzzPattern: apps.add,
            onChannelBuzzPattern: channels.add,
          ));
      final channel = find.byKey(const ValueKey('buzz-pattern:channel:apps'));
      expect(channel, findsOneWidget);
      await t.tap(channel);
      expect(channels, ['apps']);
      for (final pkg in ['com.whatsapp', 'org.telegram.messenger']) {
        final c = find.byKey(ValueKey('buzz-pattern:app:$pkg'));
        expect(c, findsOneWidget, reason: pkg);
        await t.tap(c);
      }
      expect(apps, ['com.whatsapp', 'org.telegram.messenger']);
    });
  });

  group('BuzzPatternSheet: "Tap your pattern"', () {
    testWidgets('records taps, ends after 2 s idle, plays on the band once',
        (t) async {
      final played = <BuzzSequence>[];
      final saved = <BuzzSequence>[];
      var phone = 0;
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
              bandConnected: true,
              onPhoneBuzz: () => phone++,
              onPlay: (s) async {
                played.add(s);
                return true;
              },
              onSave: saved.add,
            ),
          ));
      expect(find.textContaining(RegExp('phone must be connected',
              caseSensitive: false)),
          findsWidgets);
      final button = find.text('Tap your pattern');
      expect(button, findsOneWidget);
      await t.tap(button);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(button);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(button);
      expect(phone, 1, reason: 'the first tap buzzes the phone');
      await t.pump(const Duration(milliseconds: 1900));
      expect(played, isEmpty, reason: 'still recording before 2 s idle');
      await t.pump(const Duration(milliseconds: 200));
      await t.pumpAndSettle();
      expect(played, [BuzzSequence(const [0, 400, 800])]);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Record again'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(saved, [BuzzSequence(const [0, 400, 800])]);
    });

    testWidgets('band not connected: nothing is played, Save still works',
        (t) async {
      final played = <BuzzSequence>[];
      final saved = <BuzzSequence>[];
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
              bandConnected: false,
              onPlay: (s) async {
                played.add(s);
                return true;
              },
              onSave: saved.add,
            ),
          ));
      await t.tap(find.text('Tap your pattern'));
      await t.pump(const Duration(milliseconds: 2100));
      await t.pumpAndSettle();
      expect(played, isEmpty);
      await t.tap(find.text('Save'));
      expect(saved, [BuzzSequence(const [0])]);
    });

    testWidgets('Record again clears the take', (t) async {
      final saved = <BuzzSequence>[];
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(bandConnected: false, onSave: saved.add),
          ));
      await t.tap(find.text('Tap your pattern'));
      await t.pump(const Duration(milliseconds: 2100));
      await t.pumpAndSettle();
      await t.tap(find.text('Record again'));
      await t.pumpAndSettle();
      expect(find.text('Save'), findsNothing);
      final button = find.text('Tap your pattern');
      await t.tap(button);
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(button);
      await t.pump(const Duration(milliseconds: 2100));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      expect(saved, [BuzzSequence(const [0, 500])]);
    });
  });

  // 8AC: the extended haptics opset rule toggle.
  group('BuzzPatternSheet: extended haptics opset switch', () {
    testWidgets('a switch, off by default, with its label and caption',
        (t) async {
      await _pump(t, Scaffold(body: BuzzPatternSheet(bandConnected: false)));
      expect(find.byKey(_extKey), findsOneWidget);
      expect(_switchOn(t), isFalse);
      expect(find.text('Extended haptics opset'), findsOneWidget);
      expect(find.text('Timings may vary unexpectedly.'), findsOneWidget);
    });

    testWidgets('starts from the rule\'s own setting', (t) async {
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
                initial: _ext(const [0, 300]), bandConnected: false),
          ));
      expect(_switchOn(t), isTrue);
    });

    testWidgets('a rule without it starts off', (t) async {
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
                initial: BuzzSequence(const [0, 300]), bandConnected: false),
          ));
      expect(_switchOn(t), isFalse);
    });

    testWidgets('on before the take: the saved and the played sequence '
        'carry it', (t) async {
      final saved = <BuzzSequence>[];
      final played = <BuzzSequence>[];
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
              bandConnected: true,
              onPlay: (s) async {
                played.add(s);
                return true;
              },
              onSave: saved.add,
            ),
          ));
      await t.tap(find.byKey(_extKey));
      await t.pumpAndSettle();
      expect(_switchOn(t), isTrue);
      await _takeTwoTaps(t);
      expect(played, hasLength(1));
      expect(_extendedOf(played.single), isTrue);
      expect(played.single.offsetsMs, [0, 400]);
      await t.tap(find.text('Save'));
      expect(saved, hasLength(1));
      expect(_extendedOf(saved.single), isTrue);
      expect(saved.single.offsetsMs, [0, 400]);
    });

    testWidgets('off: the saved sequence is not extended', (t) async {
      final saved = <BuzzSequence>[];
      await _pump(
          t,
          Scaffold(body: BuzzPatternSheet(bandConnected: false, onSave: saved.add)));
      await _takeTwoTaps(t);
      await t.tap(find.text('Save'));
      expect(_extendedOf(saved.single), isFalse);
    });

    testWidgets('switched after the take: Save carries it, nothing is '
        'recorded or played again', (t) async {
      final saved = <BuzzSequence>[];
      final played = <BuzzSequence>[];
      await _pump(
          t,
          Scaffold(
            body: BuzzPatternSheet(
              bandConnected: true,
              onPlay: (s) async {
                played.add(s);
                return true;
              },
              onSave: saved.add,
            ),
          ));
      await _takeTwoTaps(t);
      expect(played, hasLength(1));
      await t.tap(find.byKey(_extKey));
      await t.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget,
          reason: 'the take is kept, no re-record');
      expect(find.text('Tap your pattern'), findsNothing);
      expect(played, hasLength(1), reason: 'no second playback');
      await t.tap(find.text('Save'));
      expect(saved.single.offsetsMs, [0, 400]);
      expect(_extendedOf(saved.single), isTrue);
    });

    testWidgets('Record again keeps the switch where it was', (t) async {
      await _pump(
          t, Scaffold(body: BuzzPatternSheet(bandConnected: false)));
      await t.tap(find.byKey(_extKey));
      await t.pumpAndSettle();
      await _takeTwoTaps(t);
      await t.tap(find.text('Record again'));
      await t.pumpAndSettle();
      expect(_switchOn(t), isTrue);
    });

    testWidgets('no profile: today\'s text only, no notes, no plan',
        (t) async {
      await _pump(
          t, Scaffold(body: BuzzPatternSheet(bandConnected: true, onPlay: (_) async => true)));
      expect(
          find.text('On MG, a long press plays the buzz twice, so lengths are '
              'close, not exact. On 4.0 a long press plays as a short buzz.'),
          findsOneWidget);
      await _takeTwoTaps(t);
      expect(find.textContaining(RegExp(r'N\d+(ff|f|mf|mp|p|pp)\b')),
          findsNothing);
      expect(find.textContaining(RegExp(r'\d+ commands?')), findsNothing);
      expect(find.textContaining('2 buzzes recorded'), findsOneWidget);
    });
  });
}
