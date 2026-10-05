// 8AF.6 G.3 (red first): the HR zone alert is a full alert, in Alerts.
//
// It gets what every other alert has (a destination picker, Off / Phone / Band
// / Phone + Band, and a Buzz pattern row that opens the picker), plus its own
// target zone (today's "Target zone" cycle) and a button "Zone view" (key
// `zone-alert-open-zones`) that opens the existing zone screen (ZonesDetail).
// The old "HR zone alert" and "Target zone" rows leave Settings > Band (one
// home). The old zoneAlertEnabled pref is migrated into the rule's
// destinations once.
//
// Contracts these tests pin that the spec leaves open:
//  - NotificationSettingsView keeps `prefs`, `onChanged`, `onBuzzPattern`; the
//    zone row is its standard alert row (title "HR zone alert", key
//    `buzz-pattern:zone` on the Buzz pattern row, destination labels as every
//    other row).
//  - The target zone control is a row titled "Target zone" with the value
//    "Zone N", drawn always and dimmed while the alert is off (8K). The view
//    takes `zoneAlertZone` (int, default 3) and `onCycleZoneAlertZone`
//    (VoidCallback), the names MoreSettingsView used. They are passed through
//    Function.apply so a wrong name fails that test, not the file.
//  - The "Zone view" button either calls `onOpenZones` (an optional
//    VoidCallback on the view, passed the same way) or pushes ZonesDetail
//    itself; either passes.
//  - Migration: when the stored alert blob and the old pref disagree, the pref
//    decides once (on -> band, off -> off). A rule that already agrees is left
//    alone (phone + band stays). After that the pref cannot change the rule
//    again.
//  - AppState no longer reads the pref itself to decide whether to watch the
//    zone (no `zoneAlertEnabled ?` arming ternary, no getter over the pref).
//
// Not covered here, for the green phase: a live session's tick dispatching
// 'zone' through AppState._dispatchBandAlert needs a test seam (there is none
// today); the delivery tests below use the production dispatcher with the
// zone rule the migration produces.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart' show ZonesDetail;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dart_source.dart';
import 'support/sections.dart';

const _pref = 'workout.zone_alert_enabled';

NotificationPrefs _withZone(int mask) {
  const p = NotificationPrefs();
  return p.withAlertRule({
    ...p.alertRule('zone').toJson(),
    'enabled': mask != 0,
    'destinations': mask,
  });
}

Widget _view(
  NotificationPrefs prefs, {
  Future<void> Function(NotificationPrefs)? onChanged,
  void Function(String)? onBuzzPattern,
  int? zone,
  VoidCallback? onCycleZone,
  VoidCallback? onOpenZones,
}) {
  final named = <Symbol, dynamic>{
    #prefs: prefs,
    #relaySupported: true,
    #onChanged: onChanged,
    #onBuzzPattern: onBuzzPattern,
    #zoneAlertZone: ?zone,
    #onCycleZoneAlertZone: ?onCycleZone,
    #onOpenZones: ?onOpenZones,
  };
  try {
    return Function.apply(NotificationSettingsView.new, const [], named)
        as Widget;
  } on NoSuchMethodError {
    // A name this build does not have: the plain view, so the test fails on
    // what it asserts (a missing row or callback), not on a crash.
    return NotificationSettingsView(
      prefs: prefs,
      relaySupported: true,
      onChanged: onChanged,
      onBuzzPattern: onBuzzPattern,
    );
  }
}

/// The column of the zone alert's row: the Buzz pattern row's nearest column.
Finder _zoneRow() => find
    .ancestor(
      of: find.byKey(const ValueKey('buzz-pattern:zone')),
      matching: find.byType(Column),
    )
    .first;

Finder _option(String label) =>
    find.descendant(of: _zoneRow(), matching: find.text(label));

/// A stored alert blob whose zone rule is [zone], and the old pref [pref].
Map<String, Object> _store({required AlertRule zone, required bool pref}) => {
      NotificationPrefs.storageKey: jsonEncode(
        const NotificationPrefs().withAlertRule(zone.toJson()).toJson(),
      ),
      _pref: pref,
    };

AlertRule _zoneRule(int mask) => const NotificationPrefs()
    .alertRule('zone')
    .copyWith(enabled: mask != 0, destinations: mask);

Future<AlertRule> _loadZone() async =>
    (await NotificationPrefs.load()).alertRule('zone');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Alerts: the HR zone alert is a full alert', () {
    testWidgets('it has a row, with the same destination labels as the '
        'others', (t) async {
      await pumpTall(t, _view(_withZone(AlertRule.band)));
      expect(find.text('HR zone alert'), findsOneWidget);
      expect(find.byKey(const ValueKey('buzz-pattern:zone')), findsOneWidget);
      for (final label in ['Off', 'Phone', 'Band', 'Phone + Band']) {
        expect(_option(label), findsOneWidget, reason: label);
      }
    });

    for (final (label, mask) in [
      ('Off', 0),
      ('Phone', AlertRule.phone),
      ('Band', AlertRule.band),
      ('Phone + Band', AlertRule.phone | AlertRule.band),
    ]) {
      testWidgets('picking "$label" hands back a zone rule with '
          'destinations $mask', (t) async {
        NotificationPrefs? next;
        // Start from a different choice so the pick is a change.
        final start = mask == AlertRule.band ? 0 : AlertRule.band;
        await pumpTall(
          t,
          _view(_withZone(start), onChanged: (p) async => next = p),
        );
        await t.tap(_option(label));
        await t.pump();
        expect(next, isNotNull);
        final rule = next!.alertRule('zone');
        expect(rule.destinations, mask);
        expect(rule.enabled, mask != 0);
      });
    }

    testWidgets('the Buzz pattern row opens the picker for the zone rule',
        (t) async {
      final picked = <String>[];
      await pumpTall(
        t,
        _view(_withZone(AlertRule.band), onBuzzPattern: picked.add),
      );
      await t.tap(find.byKey(const ValueKey('buzz-pattern:zone')));
      expect(picked, ['zone']);
    });

    testWidgets('with the alert off the Buzz pattern row is drawn and inert '
        '(8K)', (t) async {
      final picked = <String>[];
      await pumpTall(t, _view(_withZone(0), onBuzzPattern: picked.add));
      final row = find.byKey(const ValueKey('buzz-pattern:zone'));
      expect(row, findsOneWidget);
      await t.tap(row, warnIfMissed: false);
      expect(picked, isEmpty);
    });

    testWidgets('Target zone is here, shows the zone, and cycles on tap',
        (t) async {
      var cycles = 0;
      await pumpTall(
        t,
        _view(_withZone(AlertRule.band),
            zone: 4, onCycleZone: () => cycles++),
      );
      expect(find.text('Target zone'), findsOneWidget);
      expect(find.text('Zone 4'), findsOneWidget);
      await t.tap(find.text('Target zone'));
      expect(cycles, 1);
    });

    testWidgets('Target zone is always drawn, dimmed while the alert is off, '
        'live while it is on', (t) async {
      await pumpTall(t, _view(_withZone(0)));
      expect(find.text('Target zone'), findsOneWidget);
      expect(isDimmed(t, find.text('Target zone')), isTrue);
      await pumpTall(t, _view(_withZone(AlertRule.phone)));
      expect(isDimmed(t, find.text('Target zone')), isFalse);
    });

    testWidgets('the "Zone view" button opens the existing zone screen',
        (t) async {
      var opened = 0;
      await pumpTall(
        t,
        _view(_withZone(AlertRule.band), onOpenZones: () => opened++),
      );
      final button = find.byKey(const ValueKey('zone-alert-open-zones'));
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.text('Zone view')),
        findsOneWidget,
      );
      await t.tap(button);
      await t.pumpAndSettle();
      expect(
        opened > 0 || find.byType(ZonesDetail).evaluate().isNotEmpty,
        isTrue,
        reason: 'neither the callback ran nor ZonesDetail was pushed',
      );
    });

    testWidgets('the button is drawn with the alert off too (8K)', (t) async {
      await pumpTall(t, _view(_withZone(0)));
      expect(find.byKey(const ValueKey('zone-alert-open-zones')),
          findsOneWidget);
    });
  });

  group('Settings > Band lost the old rows (one home)', () {
    testWidgets('no "HR zone alert" and no "Target zone" in Settings',
        (t) async {
      await pumpTall(t, const MoreSettingsView());
      expect(find.text('HR zone alert'), findsNothing);
      expect(find.text('Target zone'), findsNothing);
      expect(find.textContaining('crosses into or out of'), findsNothing);
    });

    test('Alerts reaches the zone screen from settings.dart', () {
      final code = codeOnly(
        File('lib/ui2/profile/settings.dart').readAsStringSync(),
      );
      expect(code, contains('ZonesDetail'));
      final raw = File('lib/ui2/profile/settings.dart').readAsStringSync();
      expect(raw, contains('zone-alert-open-zones'));
    });
  });

  group('AppState keeps no second home for the switch', () {
    test('no arming ternary on the old getter, no getter over the pref', () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(RegExp(r'zoneAlertEnabled\s*\?').hasMatch(code), isFalse,
          reason: 'a session arms the crossing watcher from the zone rule, '
              'not from the old pref');
      expect(
        RegExp(r'bool get zoneAlertEnabled\s*=>\s*Prefs\.getBool')
            .hasMatch(src),
        isFalse,
      );
    });

    test('_dispatchBandAlert still resolves the rule and its pattern',
        () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final body = codeOnly(
        bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert('),
      );
      expect(body, contains('alertRule(ruleId)'));
      expect(body, contains('buzzSequenceFor(ruleId)'));
    });
  });

  group('migration of the old zoneAlertEnabled pref', () {
    test('on, with a rule that is off: the rule goes to the band', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(0), pref: true));
      final z = await _loadZone();
      expect(z.destinations, AlertRule.band);
      expect(z.enabled, isTrue);
    });

    test('off, with a rule that is on: the rule goes off', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(AlertRule.band), pref: false));
      final z = await _loadZone();
      expect(z.destinations, 0);
      expect(z.enabled, isFalse);
    });

    test('on, with a rule that already has destinations: left as it is '
        '(Phone + Band stays)', () async {
      SharedPreferences.setMockInitialValues(_store(
          zone: _zoneRule(AlertRule.phone | AlertRule.band), pref: true));
      expect((await _loadZone()).destinations,
          AlertRule.phone | AlertRule.band);
    });

    test('off, with a rule that is off: stays off', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(0), pref: false));
      expect((await _loadZone()).destinations, 0);
    });

    test('a fresh install keeps today\'s defaults: on -> band, off -> off',
        () async {
      SharedPreferences.setMockInitialValues({_pref: true});
      expect((await _loadZone()).destinations, AlertRule.band);
      SharedPreferences.setMockInitialValues({_pref: false});
      expect((await _loadZone()).destinations, 0);
    });

    test('idempotent: loading again gives the same rule and the same '
        'stored bytes', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(0), pref: true));
      final first = await _loadZone();
      final sp = await SharedPreferences.getInstance();
      final bytes = sp.getString(NotificationPrefs.storageKey);
      final second = await _loadZone();
      expect(second.destinations, first.destinations);
      expect(first.destinations, AlertRule.band, reason: 'it did migrate');
      expect(sp.getString(NotificationPrefs.storageKey), bytes);
    });

    test('once migrated, the user\'s own choice is not undone by the old '
        'pref', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(0), pref: true));
      final migrated = await NotificationPrefs.load();
      expect(migrated.alertRule('zone').destinations, AlertRule.band,
          reason: 'it did migrate');
      await migrated
          .withAlertRule(migrated
              .alertRule('zone')
              .copyWith(destinations: AlertRule.phone | AlertRule.band)
              .toJson())
          .save();
      final sp = await SharedPreferences.getInstance();
      // The old switch flips behind the app's back (an old build, a restore).
      await sp.setBool(_pref, false);
      expect((await _loadZone()).destinations,
          AlertRule.phone | AlertRule.band);
      await sp.setBool(_pref, true);
      expect((await _loadZone()).destinations,
          AlertRule.phone | AlertRule.band);
    });
  });

  group('delivery follows the rule the migration produces', () {
    Future<(int, int)> deliver(AlertRule rule) async {
      var phones = 0, bands = 0;
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final d = app.debugAlertDispatcher(
        phone: () async {
          phones++;
          return true;
        },
        band: () async {
          bands++;
          return true;
        },
        isConnected: () => true,
        now: () => DateTime(2026, 10, 3, 12),
      );
      await d.dispatch(
        rule,
        eventId: 'zone:1',
        sourceTime: DateTime(2026, 10, 3, 12),
        historical: false,
      );
      return (phones, bands);
    }

    test('an upgraded user with the old switch on gets the band, not the '
        'phone', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(0), pref: true));
      expect(await deliver(await _loadZone()), (0, 1));
    });

    test('an upgraded user with it off gets nothing', () async {
      SharedPreferences.setMockInitialValues(
          _store(zone: _zoneRule(AlertRule.band), pref: false));
      expect(await deliver(await _loadZone()), (0, 0));
    });

    for (final (name, mask, want) in [
      ('phone', AlertRule.phone, (1, 0)),
      ('band', AlertRule.band, (0, 1)),
      ('phone + band', AlertRule.phone | AlertRule.band, (1, 1)),
      ('off', 0, (0, 0)),
    ]) {
      test('the zone rule set to $name delivers to exactly those', () async {
        expect(await deliver(_zoneRule(mask)), want);
      });
    }
  });
}
