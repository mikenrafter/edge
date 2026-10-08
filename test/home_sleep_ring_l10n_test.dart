// Every new sleep-ring string exists in EVERY locale file (glob, so a newly
// added locale is covered) and the English plural is a real ICU plural.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _keys = [
  'homeSleepPctOf',
  'homeSleepPctOfDefault',
  'homeSleepOnTrack',
  'homeSleepOnTrackDefault',
  'homeSleepNoEstimate',
  'homeSleepNoEstimateWhy',
];

void main() {
  final files = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'app_[a-zA-Z_]+\.arb$').hasMatch(f.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the locale glob finds every arb (including zh)', () {
    final names = files.map((f) => f.uri.pathSegments.last).toSet();
    expect(names, containsAll(['app_en.arb', 'app_zh.arb']));
  });

  for (final f in files) {
    test('${f.uri.pathSegments.last} has every sleep-ring key, non-empty', () {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final k in _keys) {
        expect(j[k], isA<String>(), reason: '$k missing in ${f.path}');
        expect((j[k] as String).trim(), isNotEmpty, reason: k);
      }
    });
  }

  test('English: percentages, default label and cycle plural', () {
    final j = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    expect(j['homeSleepPctOf'], '{pct}% of {target}');
    expect(j['homeSleepPctOfDefault'], '{pct}% of {target} (default)');
    expect(j['homeSleepNoEstimate'], 'No estimate');
    final onTrack = j['homeSleepOnTrack'] as String;
    expect(onTrack, contains('{cycles, plural'));
    expect(onTrack, contains('=1{1 cycle}'));
    expect(onTrack, contains('{duration}'));
    final onTrackDefault = j['homeSleepOnTrackDefault'] as String;
    expect(onTrackDefault, contains('{cycles, plural'));
    expect(onTrackDefault, contains('{target}'));
    expect(onTrackDefault, contains('(default)'));
  });
}
