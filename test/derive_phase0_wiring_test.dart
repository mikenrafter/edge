// Structural checks for the first incremental-analytics steps: results leave a
// worker isolate by ownership move (`Isolate.exit`, no copy back), the batch
// activity curve is not computed a second time, and the stages of a pass are
// timed. Source-level because none of these can be seen from a result.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// The text of the first member whose declaration contains [signature], cut by
/// brace depth over [code] (comments and strings already blanked).
String _body(String code, String signature) {
  final at = code.indexOf(signature);
  expect(at, isNonNegative, reason: 'missing $signature');
  final open = RegExp(r'\)\s*(async\s*)?\{').firstMatch(code.substring(at))!.end -
      1 +
      at;
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}' && --depth == 0) return code.substring(open, i + 1);
  }
  fail('unbalanced braces after $signature');
}

void main() {
  final engine = stripCommentsAndStrings(
      File('lib/compute/derivation_engine.dart').readAsStringSync());
  final prepare = stripCommentsAndStrings(
      File('lib/compute/derive_prepare.dart').readAsStringSync());
  final engineRaw =
      File('lib/compute/derivation_engine.dart').readAsStringSync();

  group('results move out of the worker, they are not copied back', () {
    test('the cancellable isolate entry exits with the result', () {
      final b = _body(engine, 'static Future<void> _cancellableIsolateEntry');
      expect(b, contains('Isolate.exit(sendPort'));
      expect(b, isNot(contains('sendPort.send(_IsolateValue')));
    });

    test('the day-blocks isolate entry exits with the result', () {
      final b = _body(engine, 'static void _dayBlocksIsolateEntry');
      expect(b, contains('Isolate.exit(sendPort'));
      expect(b, isNot(contains('sendPort.send(_computeDayBlocks')));
    });

    test('the prepare worker exits with the substrate / prepared day', () {
      final b = _body(prepare, 'void derivationPrepareWorker');
      expect('Isolate.exit('.allMatches(b).length, 2,
          reason: 'one exit per result kind');
      expect(b, isNot(contains("mainSendPort.send({\n            'type': 'result'")));
    });
  });

  group('the batch activity curve is not recomputed', () {
    test('_computeDayBlocks no longer calls _activityCurve', () {
      final b = _body(engine, 'static _DayBlocksOutput _computeDayBlocks');
      expect(b, isNot(contains('_activityCurve(')));
    });

    test('the wake-features fallback for a stateless caller remains', () {
      expect('_activityCurve(daySub)'.allMatches(engine).length, 1);
    });
  });

  group('the stages of a pass are timed', () {
    for (final stage in const [
      'stage_candidate',
      'load_search',
      'load_day',
      'load_sleep',
      'bundle_isolate',
      'blocks_isolate',
      'fingerprints',
      'crossday',
      'baselines',
      'notifications',
    ]) {
      test(stage, () => expect(engineRaw, contains("'$stage'")));
    }
  });
}
