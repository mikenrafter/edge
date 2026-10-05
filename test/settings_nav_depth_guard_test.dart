// 8A — the navigation-depth table, and the stateful wrappers' wiring.
// See test/phase8/CONTRACTS.md §8A.
//
// docs/navigation-depth.md holds ONE markdown table with a header row whose
// cells include "Screen", "Before" and "After". Each body row names a settings
// screen and its push path before and after, written as "Settings → A → B"
// (→, U+2192). "Before" is 8AE (paths start at a Profile home); "After" is
// 8AF.7, when Settings became the landing. Depth = number of arrows.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

const _required = [
  'Settings',
  'Alerts and notifications',
  'App notifications on the band',
  'Gestures',
  'Haptics',
  'Alarm',
  'Automation',
  'Data',
  'Device detail',
  'Device lab',
  'Edit profile',
  'Live devices',
  'AI coach',
  'Language',
  'Storage',
];

List<List<String>> _rows(String md) {
  final lines = md.split('\n').where((l) => l.trim().startsWith('|')).toList();
  return [
    for (final l in lines)
      l.trim().substring(1, l.trim().length - 1).split('|').map((c) => c.trim()).toList(),
  ];
}

int _depth(String path) => '→'.allMatches(path).length;

void main() {
  group('docs/navigation-depth.md', () {
    final f = File('docs/navigation-depth.md');

    test('exists', () => expect(f.existsSync(), isTrue));

    test('has a Screen/Before/After table covering every settings screen', () {
      final rows = _rows(f.readAsStringSync());
      expect(rows, isNotEmpty);
      final header = rows.first;
      final screen = header.indexOf('Screen');
      final before = header.indexOf('Before');
      final after = header.indexOf('After');
      expect([screen, before, after], everyElement(greaterThanOrEqualTo(0)));
      final body = rows
          .skip(1)
          .where((r) => !r.every((c) => RegExp(r'^:?-+:?$').hasMatch(c)))
          .toList();
      final names = {for (final r in body) r[screen]};
      for (final s in _required) {
        expect(names, contains(s), reason: 'row for $s');
      }
      for (final r in body) {
        expect(r[after], startsWith('Settings'), reason: r[screen]);
        expect(_depth(r[after]), lessThanOrEqualTo(2),
            reason: '${r[screen]} after 8AF.7: ${r[after]}');
        // My devices was already one push from the old Profile home (a Quick
        // access row), so Device detail keeps its depth; nothing gets deeper.
        expect(_depth(r[before]),
            r[screen] == 'Device detail'
                ? equals(_depth(r[after]))
                : greaterThan(_depth(r[after])),
            reason: '${r[screen]} gets one push shallower');
      }
    });
  });

  group('stateful wrappers wire the new rows to the real screens', () {
    test('MoreSettings: every row moved in from Profile has its push', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final build = codeOnly(bodyOf(src, 'class _MoreSettingsState'));
      expect(build, contains('onBandNotifications:'));
      expect(build, contains('BandNotifications()'));
      expect(build, contains('onGestures:'));
      expect(build, contains('BandGestures()'));
      expect(build, contains('relaySupported:'));
      expect(build, contains('onEditSleepSchedule:'));
      expect(build, contains('expectedSleepSchedule:'));
      expect(build, contains('onDevices:'));
      expect(build, contains('MyDevices()'));
      expect(build, contains('onEditProfile:'));
      expect(build, contains('EditProfile()'));
      expect(build, contains('onCoach:'));
      expect(build, contains('CoachSetup()'));
      expect(build, contains('onLiveDevices:'));
      expect(build, contains('LiveDevices()'));
      expect(build, contains('onDeviceLab:'));
      expect(build, contains('DeviceLab()'));
    });

    test('openProfile: the Profile entry opens Settings, nothing between', () {
      final src = File('lib/ui2/profile/profile.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(code, contains('void openProfile(BuildContext c) => '
          'goto(c, const MoreSettings());'));
      expect(code, isNot(contains('class ProfileHome')));
    });

    test('DeviceDetail: no Device lab entry any more', () {
      final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
      final detail = codeOnly(bodyOf(src, 'class _DeviceDetailState'));
      expect(detail, isNot(contains('onDeviceLab:')));
      expect(detail, isNot(contains('DeviceLab(')));
    });
  });
}
