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
  'Notifications',
  'Band notifications',
  'Gestures',
  'Alarm',
  'Automation',
  'Data',
  'Device detail',
  'Edit profile',
  'Live devices',
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
        expect(r[after], startsWith('Profile'), reason: r[screen]);
        expect(_depth(r[after]), lessThanOrEqualTo(2),
            reason: '${r[screen]} after 8A: ${r[after]}');
        expect(_depth(r[before]), greaterThanOrEqualTo(_depth(r[after])),
            reason: '${r[screen]} never gets deeper');
      }
    });
  });

  group('stateful wrappers wire the new rows to the real screens', () {
    test('MoreSettings: Band notifications, Gestures, Expected sleep schedule',
        () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final build = codeOnly(bodyOf(src, 'class _MoreSettingsState'));
      expect(build, contains('onBandNotifications:'));
      expect(build, contains('BandNotifications()'));
      expect(build, contains('onGestures:'));
      expect(build, contains('BandGestures()'));
      expect(build, contains('relaySupported:'));
      expect(build, contains('onEditSleepSchedule:'));
      expect(build, contains('expectedSleepSchedule:'));
    });

    test('ProfileHome: Live devices', () {
      final src = File('lib/ui2/profile/profile.dart').readAsStringSync();
      final home = codeOnly(bodyOf(src, 'class _ProfileHomeState'));
      expect(home, contains('onLiveDevices:'));
      expect(home, contains('LiveDevices()'));
    });

    test('DeviceDetail: Device lab', () {
      final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
      final detail = codeOnly(bodyOf(src, 'class _DeviceDetailState'));
      expect(detail, contains('onDeviceLab:'));
      expect(detail, contains('DeviceLab('));
    });
  });
}
