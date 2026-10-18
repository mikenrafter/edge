// The native launch window is the first paint, in BOTH light and dark mode.
// A light launch background flashes white at a dark-theme user's eyes, so each
// native colour must pass the same brightness rule as checkFirstPaint.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

int _androidLaunch(String path) {
  final xml = File(path).readAsStringSync();
  final m = RegExp(r'<color name="launch_background">#([0-9A-Fa-f]{6,8})</color>')
      .firstMatch(xml);
  expect(m, isNotNull, reason: '$path has no launch_background');
  final hex = m!.group(1)!;
  final v = int.parse(hex, radix: 16);
  return hex.length == 6 ? 0xFF000000 | v : v;
}

int _component(Object? v) {
  final s = '$v';
  if (s.startsWith('0x') || s.startsWith('0X')) return int.parse(s.substring(2), radix: 16);
  if (s.contains('.')) return (double.parse(s) * 255).round();
  return int.parse(s);
}

List<int> _iosLaunch() {
  final j = jsonDecode(File(
          'ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json')
      .readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final e in (j['colors'] as List).cast<Map<String, dynamic>>())
      0xFF000000 |
          (_component((e['color'] as Map)['components']['red']) << 16) |
          (_component((e['color'] as Map)['components']['green']) << 8) |
          _component((e['color'] as Map)['components']['blue'])
  ];
}

void main() {
  const p = ShiftPolicy.standard;

  test('android values/colors.xml launch_background is dark', () {
    final c = _androidLaunch('android/app/src/main/res/values/colors.xml');
    expect(checkFirstPaint(0, c, p), ShiftSeverity.none,
        reason: '0x${c.toRadixString(16)}');
  });

  test('android values-night/colors.xml launch_background is dark', () {
    final c = _androidLaunch('android/app/src/main/res/values-night/colors.xml');
    expect(checkFirstPaint(0, c, p), ShiftSeverity.none,
        reason: '0x${c.toRadixString(16)}');
  });

  test('ios LaunchBackground has a light-mode and a dark-mode entry', () {
    expect(_iosLaunch(), hasLength(2));
  });

  test('every ios LaunchBackground entry is dark', () {
    for (final c in _iosLaunch()) {
      expect(checkFirstPaint(0, c, p), ShiftSeverity.none,
          reason: '0x${c.toRadixString(16)}');
    }
  });
}
