// 8V source guards for the hardware probes' wiring in AppState (structural:
// reads lib/). A probe that is not fed live band events or live ECG packets
// measures nothing, and a probe buzz that skips the dispatcher breaks the
// one-band-buzz-path rule (test/phase7/audit_guards_test.dart covers the
// general rule; these pin the probe's own call sites).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../phase8/support/dart_source.dart';

void main() {
  final src = File('lib/state/app_state.dart').readAsStringSync();
  final code = codeOnly(src);
  // The gesture cues and the ECG tap session live in the gesture controller
  // (8AJ seam 3); the onFrame fan-out and the event path stay in AppState.
  final gsrc = File('lib/state/gesture_controller.dart').readAsStringSync();
  final gcode = codeOnly(gsrc);

  test('the live band-event path feeds hardwareProbes.onBandEvent', () {
    final body = bodyOf(src, 'void _onLiveEvent(');
    expect(body, isNotEmpty);
    expect(body, contains('hardwareProbes.onBandEvent('));
  });

  test('the ECG onFrame fan-out feeds the probes and the tap session', () {
    final at = code.indexOf('c.onFrame =');
    expect(at, isNonNegative, reason: 'the controller callback is assigned');
    final body = code.substring(at, code.indexOf(';\n    return c;', at));
    expect(body, contains('hardwareProbes.onFrame('));
    expect(body, contains('_gestures.onEcgFrame('));
  });

  test('the probe buzz is a dispatcher delivery that hears the band reply', () {
    final body = bodyOf(src, 'Future<bool> _probeBuzz(');
    expect(body, isNotEmpty);
    final c = codeOnly(body);
    final buzz = RegExp(
      r'engine\.buzzBand\(onReply:\s*onReply\)',
    ).firstMatch(c);
    expect(buzz, isNotNull, reason: 'the reply is passed through');
    expect(
      enclosedByCall(c, buzz!.start, RegExp(r'alertDispatcher\.dispatch\(')),
      isTrue,
      reason: 'engine.buzzBand sits inside alertDispatcher.dispatch(',
    );
  });

  test('the probe pattern is a dispatcher delivery that hears the band reply',
      () {
    final body = bodyOf(src, 'Future<bool> _probePattern(');
    expect(body, isNotEmpty);
    final c = codeOnly(body);
    expect(c, contains('hardwareProbeRule'));
    final buzz = RegExp(
      r'engine\.buzzMaverickPattern\(\s*effects:\s*effects,\s*loop:\s*loop,'
      r'\s*onReply:\s*onReply,?\s*\)',
    ).firstMatch(c);
    expect(buzz, isNotNull,
        reason: 'the effects, the loop and the reply are passed through');
    expect(
      enclosedByCall(c, buzz!.start, RegExp(r'alertDispatcher\.dispatch\(')),
      isTrue,
      reason: 'engine.buzzMaverickPattern sits inside alertDispatcher.dispatch(',
    );
  });

  test('the runner is built with the probe buzz', () {
    final at = code.indexOf('HardwareProbeRunner(');
    expect(at, isNonNegative);
    expect(
      code.substring(
        at,
        closingOf(code, at + 'HardwareProbeRunner('.length - 1),
      ),
      contains('sendBuzz: _probeBuzz'),
    );
  });

  test('...and with the probe pattern', () {
    final at = code.indexOf('HardwareProbeRunner(');
    expect(at, isNonNegative);
    expect(
      code.substring(
        at,
        closingOf(code, at + 'HardwareProbeRunner('.length - 1),
      ),
      contains('sendPattern: _probePattern'),
    );
  });

  // 8X, then 8AK: the ECG failure buzz is the "Gesture failed" cue (default:
  // one long command [47, 152] looped twice), played through the same
  // dispatcher delivery as every other gesture cue.
  test('the ECG failure buzz is the Gesture failed cue inside a dispatcher '
      'delivery', () {
    final body = bodyOf(gsrc, 'Future<bool> _ecgTapFailBuzz(');
    expect(body, isNotEmpty);
    final c = codeOnly(body);
    expect(c, contains('_gestureCue('));
    expect(c, contains('cues.failed'));
    final cue = codeOnly(bodyOf(gsrc, 'Future<bool> _gestureCue('));
    expect(cue, contains('kEcgTapRule'));
    expect(cue, contains('_alertDispatcher().dispatch('));
    expect(cue, contains('bandDelivery:'));
  });

  test('the ECG tap session is built with the failure buzz', () {
    final at = gcode.indexOf('EcgTapSession _newEcgSession() =>');
    expect(at, isNonNegative);
    final open = gcode.indexOf('EcgTapSession(', at);
    expect(
      gcode.substring(open, closingOf(gcode, open + 'EcgTapSession('.length - 1)),
      contains('failBuzz: _ecgTapFailBuzz'),
    );
  });
}
