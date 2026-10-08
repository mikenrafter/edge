// Source guard (AGENTS.md invariant 16). Device lab reports are shared as log
// files (logFileName + saveLogFile), never copied as strings to the clipboard.
//
//   * No Device lab page or runner mentions the clipboard at all, or offers a
//     "Copy ..." report control (log_no_clipboard_guard_test guards
//     `Clipboard.setData` across lib/; this one is the Device lab's own, and
//     also catches the control's wording, a `Clipboard` import and a
//     `copyReport`-style name).
//   * The termination probe card saves through saveLogFile with a
//     `termination-probe` log file name.
//   * AppState wires the termination probe the way the alarm-slot probe is
//     wired: events in, alarm events swallowed from the real handler, taps
//     held for the probe.
//   * AGENTS.md states the invariant.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

/// The Device lab's pages and runners. Every file here must exist.
const _labFiles = <String>[
  'lib/ui2/profile/device_lab.dart',
  'lib/ui2/profile/pattern_probe_page.dart',
  'lib/ui2/profile/motion_lab.dart',
  'lib/ui2/profile/alarm_slot_probe_card.dart',
  'lib/ui2/profile/termination_probe_card.dart',
  'lib/ui2/profile/live_devices.dart',
  'lib/ui2/profile/tap_take_pad.dart',
  'lib/gestures/lab_log.dart',
  'lib/gestures/hardware_probe_runner.dart',
  'lib/gestures/hardware_probes.dart',
  'lib/gestures/alarm_slot_probe.dart',
  'lib/gestures/termination_probe.dart',
  'lib/gestures/imu_recording_store.dart',
];

void main() {
  test('every Device lab file exists (the list cannot rot silently)', () {
    for (final f in _labFiles) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });

  test('no Device lab file touches the clipboard', () {
    final offenders = <String>[];
    for (final f in _labFiles) {
      if (!File(f).existsSync()) continue;
      final code = codeOnly(File(f).readAsStringSync());
      if (code.contains('Clipboard') ||
          RegExp(r'copy(Report|Log|ToClipboard)', caseSensitive: false)
              .hasMatch(code)) {
        offenders.add(f);
      }
    }
    expect(offenders, isEmpty,
        reason: 'a Device lab report is saved as a log file, not copied');
  });

  test('no Device lab file offers a "Copy ..." control', () {
    final offenders = <String>[];
    for (final f in _labFiles) {
      if (!File(f).existsSync()) continue;
      // The control's wording is inside a string literal, so comments (which
      // may still talk about the old "Copy all logs") are dropped by line.
      final raw = File(f)
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // (lab_log.dart's log header line 'Copied <time>' is a timestamp label
      // that app_state_gesture_wiring_test strips; it is not a control.)
      if (RegExp(r'''['"]Copy\b''').hasMatch(raw)) offenders.add(f);
    }
    expect(offenders, isEmpty);
  });

  test('the termination probe card saves its report through saveLogFile', () {
    final card =
        File('lib/ui2/profile/termination_probe_card.dart').readAsStringSync();
    final code = codeOnly(card);
    expect(code, contains('saveLogFile'));
    expect(code, contains('logFileName'));
    expect(card, contains("'termination-probe'"));
    expect(card, contains('Save report file'));
  });

  test('AppState wires the termination probe: events, swallow, tap hold', () {
    final code = codeOnly(File('lib/state/app_state.dart').readAsStringSync());
    expect(code, contains('terminationProbe.onBandEvent('));
    expect(code, contains('terminationProbe.swallowsEvent('));
    expect(RegExp(r'labHold:[^;]*terminationProbe\.holdsTaps').hasMatch(code),
        isTrue,
        reason: 'a tap during a run belongs to the probe');
    expect(code, contains('late final TerminationProbeRunner terminationProbe'));
  });

  test('the Device lab shows the card, in developer mode', () {
    final code =
        codeOnly(File('lib/ui2/profile/device_lab.dart').readAsStringSync());
    expect(code, contains('TerminationProbeCard('));
  });

  test('AGENTS.md states the invariant', () {
    final md = File('AGENTS.md').readAsStringSync();
    expect(md, contains('Device lab reports are shared as log files'));
    expect(md, contains('never as strings on the'));
  });
}
