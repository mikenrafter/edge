// 8AC docs (spec H): the hardware notes carry the L6 vocabulary and the
// taps-to-commands pipeline, the contracts file has the 8AC entry, and the
// roadmap lists 8AC after 8AB. Plain reads, so a doc that drifts from the
// code's names fails here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final hw = _read('docs/hardware/whoop-mg-haptics-and-ecg.md');

  group('docs/hardware/whoop-mg-haptics-and-ecg.md', () {
    test('has the L6 vocabulary section', () {
      expect(hw, contains('## Vocabulary (L6)'));
      final at = hw.indexOf('## Vocabulary (L6)');
      final next = hw.indexOf('\n## ', at + 5);
      final section = hw.substring(at, next < 0 ? hw.length : next);
      // Every phrase of the profile is in the table, by id.
      for (final p in HapticDeviceProfile.whoopMg.phrases) {
        expect(section, contains('`${p.id}`'), reason: p.id);
      }
      // The gap table's delays.
      for (final g in HapticDeviceProfile.whoopMg.gaps) {
        expect(section, contains('${g.delayMs} ms'), reason: '${g.delayMs}');
      }
      expect(section, contains('unstable'));
      expect(section, contains('R1 R2 R4'));
      expect(section, contains('shortest'));
      expect(section, contains('longest'));
      expect(section, contains('14 is f'));
      expect(section, contains('ff'));
      expect(section, contains('docs/hardware/logs/2026-10-03-pattern-probe-L6.txt'));
      expect(section, contains('whoop-mg-pattern-v1'));
    });

    test('has the taps-to-commands section', () {
      expect(hw, contains('## From taps to band commands'));
      final at = hw.indexOf('## From taps to band commands');
      final next = hw.indexOf('\n## ', at + 5);
      final section = hw.substring(at, next < 0 ? hw.length : next);
      for (final word in [
        'notes',
        'compiler',
        'penalty',
        'pre-bake',
        '10 s',
        'queue',
        '30 commands',
      ]) {
        expect(section.toLowerCase(), contains(word), reason: word);
      }
    });
  });

  test('CONTRACTS.md has the 8AC entry after 8AB', () {
    final c = _read('test/phase8/CONTRACTS.md');
    expect(c, contains('## 8AC:'));
    expect(c.indexOf('## 8AC:'), greaterThan(c.indexOf('## 8AB:')));
    final at = c.indexOf('## 8AC:');
    final entry = c.substring(at);
    for (final word in [
      'band_queue',
      'BandHapticQueue',
      'BandCommandLedger',
      'bakedSteps',
      '_deliverBandSequence',
      'kMaxHapticRuntime',
    ]) {
      expect(entry, contains(word), reason: word);
    }
  });

  test('the roadmap lists 8AC after 8AB', () {
    final r = _read(
        'docs/superpowers/plans/2026-09-30-controls-alerts-and-wake-roadmap.md');
    expect(r, contains('### 8AC'));
    expect(r.indexOf('### 8AC'), greaterThan(r.indexOf('### 8AB')));
    expect(r.indexOf('### 8AC'), lessThan(r.indexOf('### Order')));
  });
}
