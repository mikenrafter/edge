// 8AK B (red): AppState wires the plain double-tap route like the ECG route
// (source guards, the repo's way of pinning wiring that needs a whole AppState
// to run).
//
// ASSUMED WIRING (lib/state/app_state.dart):
//   * `_repeatTapSession` (DoubleTapRepeatSession) gets `startBuzz:` (the same
//     start cue as the ECG route, `_ecgTapStartBuzz`), `buzz:` (the follow-up,
//     `_ecgTapBuzz`, as today), `confirmBuzz:` (`_ecgTapConfirmBuzz`) and
//     `bandIdle:` (`haptics.whenIdle`). One set of cues, one path
//     (AGENTS.md 3.8: a second path is the bug).
//   * `_ecgTapSession` (EcgTapSession) gets `bandIdle:` too.
//   * Nothing else plays a confirm for a counted repeated-double-tap gesture:
//     the 8H ack in `_onLiveEvent` stays (it is silent for an outcome with
//     `taps`, see b_dispatcher_repeat_test.dart).
//
// Failure mode today: the repeat session is built with `buzz:` only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../phase8/support/dart_source.dart';

void main() {
  final src = File('lib/state/app_state.dart').readAsStringSync();
  final code = codeOnly(src);

  String between(String from, String to) {
    final a = src.indexOf(from);
    final b = src.indexOf(to, a + 1);
    expect(a, greaterThan(0), reason: from);
    expect(b, greaterThan(a), reason: to);
    return codeOnly(src.substring(a, b));
  }

  test('the repeated-double-tap session gets the same start, follow-up and '
      'confirm cues as the ECG session, and the band-idle signal', () {
    final repeat = between('late final DoubleTapRepeatSession _repeatTapSession',
        'late final EcgTapSession _ecgTapSession');
    expect(repeat, contains('startBuzz: _ecgTapStartBuzz'));
    expect(repeat, contains('buzz: (id) => _ecgTapBuzz(1, id)'));
    expect(repeat, contains('confirmBuzz: _ecgTapConfirmBuzz'));
    expect(repeat, contains('bandIdle:'));
  });

  test('the ECG session gets the band-idle signal', () {
    final ecg = between('late final EcgTapSession _ecgTapSession',
        'Completer<int?>? _tapCount;');
    expect(ecg, contains('bandIdle:'));
  });

  test('both read it from the haptics service', () {
    expect(RegExp(r'bandIdle\s*:\s*haptics\.whenIdle').allMatches(code).length,
        2);
  });
}
