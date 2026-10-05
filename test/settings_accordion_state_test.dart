// 8AF.7 section B (red first): every SettingsAccordion remembers whether it was
// open or folded, per stable key (screen id + section id, never the translated
// title), through the SettingsRepository app-prefs section.
//
//   first visit            -> expanded (today's default), nothing written
//   fold / unfold          -> one app-pref write (a bool) through
//                             SettingsRepository.update, announced on
//                             SettingsRepository.changes
//   leave and reopen       -> each section comes back the way it was left
//   another screen         -> its same-titled section is NOT affected
//                             (Settings > Hardware, once Band, vs the band's
//                             Device detail >
//                             Band)
//   another locale         -> same key, same remembered state
//
// The accordion API for passing the id is the implementer's choice, so these
// pump the real pure views (which own their ids) and observe the stored key
// through the repository's own change stream: no compile-time dependency on
// the new parameter.
//
// Every test settles the repository queue before it ends: its static future
// chain must never be left pending in a finished test's zone.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_sections.dart';

final _schedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true),
]);

final _band = HealthSource(
  name: 'Synthetic band',
  kind: 'WHOOP 4',
  tier: SourceTier.wristOptical,
  icon: LucideIcons.watch,
  connected: true,
  isBand: true,
  family: 'gen4',
);

/// Every settings screen with accordions that can be pumped headless.
Map<String, Widget Function()> get _screens => {
      'Settings': () => const MoreSettingsView(devMode: true, version: '1'),
      'Notifications': () =>
          const NotificationSettingsView(relaySupported: true),
      'App notifications on the band': () =>
          const BandNotificationsView(enabled: true, granted: true),
      'Alarm': () => AlarmScreenView(connected: true, schedule: _schedule),
      'Gestures': () => const BandGesturesView(
            chosen: {DeviceAction.markMoment},
            supported: {
              DeviceAction.none,
              DeviceAction.markMoment,
              DeviceAction.torch
            },
          ),
      'Device detail': () => DeviceDetailView(_band),
      'Edit profile': () => EditProfileView(onSave: (_) async {}),
    };

Widget _app(Widget home, {Locale? locale}) =>
    ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(locale?.languageCode),
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: home,
      ),
    );

/// Let the repository's write/read queue drain, then settle the frame.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Future<void> _open(WidgetTester t, Widget w, {Locale? locale}) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w, locale: locale));
  await _settle(t);
}

/// Leave the screen entirely (its State is disposed), then come back.
Future<void> _leave(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await _settle(t);
}

Finder _byTitle(String title) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.title == title,
    description: 'SettingsAccordion "$title"');

Finder _header(Finder accordion) =>
    find.descendant(of: accordion, matching: find.byType(Pressable)).first;

Future<void> _toggle(WidgetTester t, Finder accordion) async {
  await t.tap(_header(accordion));
  await _settle(t);
}

/// True when the accordion's rows are in the tree.
bool _isOpen(WidgetTester t, Finder accordion) {
  final a = t.widget<SettingsAccordion>(accordion);
  return find
      .descendant(of: accordion, matching: find.byWidget(a.children.first))
      .evaluate()
      .isNotEmpty;
}

/// App-pref writes announced by the repository while a test runs.
class _Writes {
  _Writes() {
    _sub = SettingsRepository.instance.changes.listen((c) {
      if (c.appPrefs.isNotEmpty) all.add(c.appPrefs);
    });
  }
  late final StreamSubscription<SettingsChange> _sub;
  final List<Map<String, Object>> all = [];
  Future<void> close() => _sub.cancel();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('first visit', () {
    testWidgets('every section starts expanded and nothing is written',
        (t) async {
      final writes = _Writes();
      addTearDown(writes.close);
      for (final e in _screens.entries) {
        await _open(t, e.value());
        await expectAllSectionsExpanded(t, e.key);
        await _leave(t);
      }
      expect(writes.all, isEmpty, reason: 'looking is not a write');
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });
  });

  group('collapse and expand persist through the repository', () {
    testWidgets('folding a section is one bool app-pref write, announced on '
        'SettingsRepository.changes', (t) async {
      final writes = _Writes();
      addTearDown(writes.close);
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('Hardware'));
      expect(_isOpen(t, _byTitle('Hardware')), isFalse);
      expect(writes.all, hasLength(1));
      final entry = writes.all.single;
      expect(entry, hasLength(1), reason: 'one section, one key');
      expect(entry.values.single, false);
      final key = entry.keys.single;
      expect(key.toLowerCase(), contains('band'),
          reason: 'the key names the section by its id');
      expect(key, isNot(matches(r'\s')),
          reason: 'an id, not a display title: $key');
      expect((await SharedPreferences.getInstance()).get(key), isNotNull,
          reason: 'it reached storage, not only memory');
    });

    testWidgets('collapse, leave, reopen: still collapsed; the others untouched',
        (t) async {
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('Hardware'));
      await _leave(t);
      await _open(t, _screens['Settings']!());
      expect(_isOpen(t, _byTitle('Hardware')), isFalse,
          reason: 'closed last visit, closed this visit');
      for (final other in ['Alerts', 'You & preferences', 'Data & privacy']) {
        expect(_isOpen(t, _byTitle(other)), isTrue, reason: other);
      }
    });

    testWidgets('expand persists: collapse, reopen, expand, reopen -> open',
        (t) async {
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('Alerts'));
      await _leave(t);
      await _open(t, _screens['Settings']!());
      expect(_isOpen(t, _byTitle('Alerts')), isFalse);
      await _toggle(t, _byTitle('Alerts'));
      expect(_isOpen(t, _byTitle('Alerts')), isTrue);
      await _leave(t);
      await _open(t, _screens['Settings']!());
      expect(_isOpen(t, _byTitle('Alerts')), isTrue,
          reason: 'opened last visit, open this visit');
    });

    testWidgets('a section that was left open stays open after another is '
        'folded', (t) async {
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('Data & privacy'));
      await _toggle(t, _byTitle('Connections'));
      await _toggle(t, _byTitle('Connections'));
      await _leave(t);
      await _open(t, _screens['Settings']!());
      expect(_isOpen(t, _byTitle('Data & privacy')), isFalse);
      expect(_isOpen(t, _byTitle('Connections')), isTrue);
    });
  });

  group('the key is screen id + section id', () {
    testWidgets('Settings > Hardware and the band page > Band are different '
        'keys',
        (t) async {
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('Hardware'));
      await _leave(t);
      await _open(t, _screens['Device detail']!());
      expect(_isOpen(t, _byTitle('Band')), isTrue,
          reason: 'folding Settings > Hardware must not fold Device '
              'detail > Band');
      await expectAllSectionsExpanded(t, 'Device detail');
    });

    testWidgets('every accordion on every screen has its own key, and each '
        'one comes back folded', (t) async {
      final writes = _Writes();
      addTearDown(writes.close);
      final seen = <String>{};
      for (final e in _screens.entries) {
        await _open(t, e.value());
        await expectAllSectionsExpanded(t, '${e.key} (not folded by another '
            'screen)');
        final n = accordions(t).length;
        writes.all.clear();
        for (var i = 0; i < n; i++) {
          await t.tap(_header(find.byType(SettingsAccordion).at(i)));
          await _settle(t);
        }
        expect(writes.all, hasLength(n), reason: '${e.key}: one write each');
        final keys = [for (final w in writes.all) w.keys.single];
        expect(keys.toSet(), hasLength(n),
            reason: '${e.key}: two sections share a key: $keys');
        expect([for (final w in writes.all) w.values.single],
            everyElement(false));
        for (final k in keys) {
          expect(seen.add(k), isTrue,
              reason: '${e.key}: key "$k" is also used on another screen');
        }
        await _leave(t);
        await _open(t, e.value());
        for (var i = 0; i < n; i++) {
          expect(_isOpen(t, find.byType(SettingsAccordion).at(i)), isFalse,
              reason: '${e.key}: section $i did not come back folded');
        }
        await _leave(t);
      }
    });
  });

  group('locale-independent', () {
    // "About" is translated ("Acerca de") by AppLocalizations, so it is the
    // section whose title changes with the locale.
    const es = Locale('es');

    testWidgets('the key written for About is the same in English and Spanish',
        (t) async {
      final writes = _Writes();
      addTearDown(writes.close);
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('About'));
      final en = writes.all.single.keys.single;
      await _leave(t);

      SharedPreferences.setMockInitialValues({});
      writes.all.clear();
      await _open(t, _screens['Settings']!(), locale: es);
      expect(_byTitle('About'), findsNothing,
          reason: 'the Spanish run really is translated');
      await _toggle(t, _byTitle('Acerca de'));
      expect(writes.all.single.keys.single, en);
      expect(en.toLowerCase(), isNot(contains('acerca')));
      await _leave(t);
    });

    testWidgets('folded in English, still folded after switching to Spanish',
        (t) async {
      await _open(t, _screens['Settings']!());
      await _toggle(t, _byTitle('About'));
      await _leave(t);
      await _open(t, _screens['Settings']!(), locale: es);
      expect(_isOpen(t, _byTitle('Acerca de')), isFalse);
      expect(_isOpen(t, _byTitle('Hardware')), isTrue);
    });
  });
}
