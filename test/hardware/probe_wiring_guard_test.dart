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
    expect(body, contains('_ecgTapSession.onFrame('));
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
}
