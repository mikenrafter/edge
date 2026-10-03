// 8A — the navigation-depth table, and the stateful wrappers' wiring.
// See test/phase8/CONTRACTS.md §8A.
//
// docs/navigation-depth.md holds ONE markdown table with a header row whose
// cells include "Screen", "Before" and "After". Each body row names a settings
// screen and its push path from Profile home before and after 8A, written as
// "Profile → A → B" (→, U+2192). Depth = number of arrows.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

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

// 8AE moved these rows from Profile into Settings, one push deeper on purpose
// (still within the two-push limit). Every other row must not get deeper.
const _movedDeeper = {
  'Edit profile',
  'Live devices',
  'AI coach',
  'Language',
  'Storage',
};

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
        expect(r[after], startsWith('Profile'), reason: r[screen]);
        expect(_depth(r[after]), lessThanOrEqualTo(2),
            reason: '${r[screen]} after 8AE: ${r[after]}');
        if (!_movedDeeper.contains(r[screen])) {
          expect(_depth(r[before]), greaterThanOrEqualTo(_depth(r[after])),
              reason: '${r[screen]} never gets deeper');
        }
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

    test('ProfileHome: My devices and Settings only', () {
      final src = File('lib/ui2/profile/profile.dart').readAsStringSync();
      final home = codeOnly(bodyOf(src, 'class _ProfileHomeState'));
      expect(home, contains('onDevices:'));
      expect(home, contains('MyDevices()'));
      expect(home, contains('onSettings:'));
      expect(home, contains('MoreSettings()'));
      expect(home, isNot(contains('LiveDevices()')));
      expect(home, isNot(contains('EditProfile()')));
      expect(home, isNot(contains('CoachSetup()')));
    });

    test('DeviceDetail: no Device lab entry any more', () {
      final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
      final detail = codeOnly(bodyOf(src, 'class _DeviceDetailState'));
      expect(detail, isNot(contains('onDeviceLab:')));
      expect(detail, isNot(contains('DeviceLab(')));
    });
  });
}
