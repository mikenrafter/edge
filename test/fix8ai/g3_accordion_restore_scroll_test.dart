// 8AI G3 (red first): "on the notification management screen sometimes it will
// lock you to the bottom area of the screen and trying to scroll up
// continually resets you down to the bottom."
//
// WHAT I COULD AND COULD NOT REPRODUCE (see the report that came with these
// tests):
//   * No jumpTo / animateTo / ensureVisible / reverse list / autofocus exists
//     on Settings > Alerts and notifications (NotificationSettingsView in
//     settings.dart), nor on App notifications on the band
//     (BandNotificationsView); plain drags and rebuilds keep the offset.
//   * REPRODUCED: the page changes HEIGHT after the user has started
//     scrolling. A SettingsAccordion is built expanded (`initiallyExpanded`
//     defaults to true) and only AFTER its first frame reads its remembered
//     answer (`_restore`, async, in initState) and folds. On a long page with
//     several folded sections the first frame is ~4600 pt tall and the settled
//     page ~1000 pt tall, so a person who starts scrolling at once is clamped
//     to the new bottom ("locks you to the bottom"), and every accordion the
//     lazy list builds later as they scroll repeats the same expand-then-fold
//     collapse under their finger.
//
// ASSUMED BEHAVIOUR: once the app prefs are loaded at start-up (main() awaits
// `Prefs.ensureLoaded()` before runApp, and the repository's reader is warm),
// a SettingsAccordion with an id builds in its REMEMBERED state on its very
// first frame: no expanded-then-folded flash, no height change after
// first layout. How it gets the answer synchronously is the implementer's
// choice (the `Prefs` synchronous cache that already exists for exactly this,
// or a warm cache in SettingsRepository); the tests warm both the same way
// main() does and assert only what is on screen.
//
// Fixture: every test stores answers through the SAME SharedPreferences
// instance Prefs holds (one setMockInitialValues in setUpAll, then plain
// writes), so Prefs' synchronous cache and the repository agree.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/g123_helpers.dart';

/// The answers a user who folded most of the long page would have stored.
const _folded = <String, bool>{
  'notifications_health': false,
  'notifications_activity': false,
  'notifications_reminders': false,
  'notifications_device': false,
};

Future<void> _store(Map<String, bool> byId) async {
  final sp = await SharedPreferences.getInstance();
  await sp.clear();
  for (final e in byId.entries) {
    await sp.setBool(accordionPrefKey(e.key), e.value);
  }
}

double _offset(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
double _max(WidgetTester t) => t
    .state<ScrollableState>(find.byType(Scrollable).first)
    .position
    .maxScrollExtent;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    await SettingsRepository.instance.appBool('warm');
  });

  group('remembered state is there on the first frame', () {
    testWidgets('Notifications: folded sections are folded after ONE pump',
        (t) async {
      await _store(_folded);
      g123View(t, height: 30000);
      await t.pumpWidget(g123App(const NotificationSettingsView()));
      // No settle, no second frame: this is what the person sees first.
      final s = openStates(t);
      expect(s['notifications_health'], isFalse,
          reason: 'built expanded, folded a frame later: the page jumps');
      expect(s['notifications_activity'], isFalse);
      expect(s['notifications_reminders'], isFalse);
      expect(s['notifications_device'], isFalse);
      expect(s['notifications_alarms_wake'], isTrue,
          reason: 'never stored: its default');
      expect(s['notifications_quiet_hours'], isTrue);
      await g123Settle(t);
    });

    testWidgets('App notifications on the band: same', (t) async {
      await _store({
        'band_notifications_apps': false,
        'band_notifications_alarms': false,
      });
      g123View(t, height: 30000);
      await t.pumpWidget(
          g123App(const BandNotificationsView(enabled: true, granted: true)));
      final s = openStates(t);
      expect(s['band_notifications_apps'], isFalse);
      expect(s['band_notifications_alarms'], isFalse);
      expect(s['band_notifications_calls'], isTrue);
      await g123Settle(t);
    });

    testWidgets('Settings: the first frame already honours a folded section',
        (t) async {
      await _store({'settings_preferences': false, 'settings_about': false});
      g123View(t, height: 30000);
      await t.pumpWidget(g123App(
          const MoreSettingsView(devMode: true, version: '1')));
      final s = openStates(t);
      expect(s['settings_preferences'], isFalse);
      expect(s['settings_about'], isFalse);
      expect(s['settings_alerts'], isTrue);
      await g123Settle(t);
    });
  });

  group('the page does not change height after it first lays out', () {
    testWidgets('Notifications: scroll extent on the first frame == settled '
        'extent', (t) async {
      await _store(_folded);
      g123View(t); // phone-sized: a lazy, scrollable list
      await t.pumpWidget(g123App(const NotificationSettingsView()));
      final first = _max(t);
      await g123Settle(t);
      final settled = _max(t);
      expect((first - settled).abs(), lessThan(1),
          reason: 'first frame max scroll $first, settled $settled: the '
              'page shrank after the user could already scroll it');
    });

    testWidgets('scrolling at once, then the page settling: the offset the '
        'user chose is kept', (t) async {
      await _store(_folded);
      g123View(t);
      await t.pumpWidget(g123App(const NotificationSettingsView()));
      // The user starts scrolling immediately, well into the page.
      await t.drag(find.byType(ListView), const Offset(0, -500));
      await t.pump();
      final chosen = _offset(t);
      expect(chosen, greaterThan(300), reason: 'the drag scrolled the page');
      await g123Settle(t);
      expect(_offset(t), closeTo(chosen, 1),
          reason: 'the page re-laid out under the finger and the offset was '
              'clamped to the new bottom');
    });

    testWidgets('after the page has settled, scrolling up stays where the '
        'user put it, through toggles and a restore', (t) async {
      await _store(_folded);
      g123View(t);
      await t.pumpWidget(g123App(const NotificationSettingsView()));
      await g123Settle(t);
      await t.fling(find.byType(ListView), const Offset(0, -3000), 3000);
      await t.pumpAndSettle();
      final atBottom = _offset(t);
      expect(atBottom, closeTo(_max(t), 1), reason: 'flung to the bottom');
      for (var i = 0; i < 4; i++) {
        await t.drag(find.byType(ListView), const Offset(0, 100));
        await t.pumpAndSettle();
        expect(_offset(t), lessThan(atBottom - 40 * (i + 1)),
            reason: 'drag $i up: the list snapped back toward the bottom');
      }
      // Fold a visible section and unfold it again: still where we were
      // (heights above the viewport do not change when we fold one below).
      final y = _offset(t);
      await toggleAccordion(t, 'notifications_quiet_hours');
      await toggleAccordion(t, 'notifications_quiet_hours');
      expect(_offset(t), lessThanOrEqualTo(y + 1));
      expect(_offset(t), lessThan(_max(t) - 50),
          reason: 'toggling must not leave the page pinned to the bottom');
    });
  });
}
