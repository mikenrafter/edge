// The Status section says what the last wake decided, in plain words. Pure.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_trace_text.dart';

WakeTraceEntry _e(String kind, Map<String, Object?> data, [int at = 0]) =>
    WakeTraceEntry(wakeEpochSec: 1, atMs: at, kind: kind, data: data);

void main() {
  test('no trace: nothing is invented', () {
    expect(describeWakeTrace(const []), isEmpty);
  });

  test('a Natural decision names the reason in plain words', () {
    final lines = describeWakeTrace([
      _e('natural', {'reason': 'noRemCandidate'}, 1),
      _e('natural', {'reason': 'lowConfidence'}, 2),
    ]);
    expect(lines.first, startsWith('Natural Wake'));
    expect(lines.first, contains('confident enough'));
    expect(lines.join(' '), isNot(contains('noRemCandidate')),
        reason: 'only the latest decision, and never the enum name');
  });

  test('every NaturalReason has words, none leaks its identifier', () {
    for (final r in NaturalReason.values) {
      final text = naturalReasonText(r.name);
      expect(text, isNotEmpty, reason: r.name);
      expect(text, isNot(contains(r.name)), reason: r.name);
    }
    expect(naturalReasonText('somethingNew'), isNotEmpty,
        reason: 'an unknown reason still gets honest words');
  });

  test('the Natural buzz and its result', () {
    final sent = describeWakeTrace([
      _e('natural_haptic', {'phase': 'request'}, 1),
      _e('natural_haptic', {'phase': 'result', 'result': 'sent'}, 2),
    ]).join('\n');
    expect(sent, contains('Natural Wake buzzed the band'));
    final lost = describeWakeTrace([
      _e('natural_haptic', {'phase': 'result', 'result': 'notDelivered'}, 2),
    ]).join('\n');
    expect(lost, contains('not delivered'));
  });

  test('Gradual steps are counted by what happened to them', () {
    final text = describeWakeTrace([
      _e('gradual', {'index': 0, 'result': 'sent'}),
      _e('gradual', {'index': 1, 'result': 'sent'}),
      _e('gradual', {'index': 2, 'result': 'skippedLate'}),
      _e('gradual', {'index': 3, 'result': 'notDelivered'}),
    ]).join('\n');
    expect(text, contains('Gradual Wake'));
    expect(text, contains('2 buzzes sent'));
    expect(text, contains('1 skipped'));
    expect(text, contains('1 not delivered'));
  });

  test('the band alarm at the wake time is armed, confirmed or not', () {
    String line(Map<String, Object?> d) =>
        describeWakeTrace([_e('fallback', d)]).single;
    expect(line({'armed': true, 'confirmed': true}),
        'Band alarm at wake time: armed and confirmed');
    expect(line({'armed': true, 'confirmed': false}),
        'Band alarm at wake time: armed, not confirmed yet');
    expect(line({'armed': false, 'confirmed': false}),
        'Band alarm at wake time: not armed');
    expect(line({'armed': null, 'confirmed': null}),
        'Band alarm at wake time: state unknown');
    expect(line({'armed': true, 'confirmed': true, 'rearmed': true}),
        contains('re-armed'));
  });

  test('an acknowledgement says whether the band alarm was cancelled', () {
    expect(
        describeWakeTrace([
          _e('ack', {'cancelNative': true, 'cancelled': true, 'fallbackArmed': false})
        ]).single,
        'You said you were up. The band alarm was cancelled');
    expect(
        describeWakeTrace([
          _e('ack', {'cancelNative': true, 'cancelled': false, 'fallbackArmed': true})
        ]).single,
        'You said you were up. The band alarm stays armed');
  });

  test('errors and skips surface instead of vanishing', () {
    final text = describeWakeTrace([
      _e('error', {'where': 'samples', 'error': 'x'}),
      _e('skip', {'reason': 'headlessGateBusy'}),
    ]).join('\n');
    expect(text, contains('samples'));
    expect(text, contains('another background sync'));
  });
}
