// kAlgoVersion 116 (analytics #99) follows 115 (D36) and 114. The 114 entry
// keeps our single bump atop upstream 113 (merge log D27 revised,
// owner 2026-10-19). Invariant 4: stored output changed, so the version moves
// and the changelog entry above the constant says why. The output changes it
// covers: D16 (our derivation changes and the analytics merge), D25 (the
// waking-HR dip hand-off), D28 (ring/wearable derive fixes) and D27 (a typed
// sleep window is staged, with per-stage minute ranges).
//
// The 116 entry names the analytics output changes; 115 keeps the D36 history.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
  final m = RegExp(r'const int kAlgoVersion = (\d+);').firstMatch(src)!;

  /// The contiguous comment block directly above the constant.
  List<String> block() {
    final lines = src.substring(0, m.start).split('\n');
    var i = lines.length - 1;
    while (i >= 0 && lines[i].trim().isEmpty) {
      i--;
    }
    final out = <String>[];
    while (i >= 0 && lines[i].trimLeft().startsWith('//')) {
      out.insert(0, lines[i]);
      i--;
    }
    return out;
  }

  test('kAlgoVersion is 116', () {
    expect(kAlgoVersion, 116);
    expect(int.parse(m.group(1)!), 116);
  });

  test('the 114 entry is kept: names its base and the decisions it covers', () {
    final b = block();
    final at = b.lastIndexWhere((l) => l.startsWith('// 114:'));
    expect(at, isNonNegative, reason: 'no 114 entry above the constant');
    final entry = b.sublist(at).join('\n');
    expect(entry, contains('single bump atop upstream 113'));
    for (final d in ['D16', 'D25', 'D28', 'D27']) {
      expect(entry, contains(d), reason: 'the 114 entry covers $d');
    }
    expect(entry, contains('stage_ranges'),
        reason: 'D27: the new bundle key is named');
    expect(b.join('\n'), isNot(contains('no separate number')));
  });

  test('the 115 entry is kept and names D36', () {
    final b = block();
    final at = b.lastIndexWhere((l) => l.startsWith('// 115:'));
    expect(at, isNonNegative, reason: 'no 115 entry above the constant');
    final end = b.indexWhere((l) => l.startsWith('// 116:'));
    expect(end, greaterThan(at));
    final entry = b.sublist(at, end).join('\n');
    expect(entry, contains('D36'));
    expect(entry, contains('target'));
  });

  test('the 116 entry closes the changelog and names analytics output changes', () {
    final b = block();
    final at = b.lastIndexWhere((l) => l.startsWith('// 116:'));
    expect(at, isNonNegative, reason: 'no 116 entry above the constant');
    final entry = b.sublist(at).join('\n');
    for (final change in ['6a2a9fc', 'hrvTime', 'banisterTrimp', 'ctlAtlTsb',
      'cosinor', 'timeInZone', 'circadianNonparametric', '32', 'non-finite',
      'IrregularScreenState', 'EpochRows']) {
      expect(entry, contains(change));
    }
    expect(entry, contains('staging labels unchanged'));
    expect(b.lastIndexWhere((l) => RegExp(r'^// \d+:').hasMatch(l)), at);
  });
}
