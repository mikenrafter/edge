// P2.5 call sites (design 02 step 2, section 5 P2.5; AGENTS.md 4.7 "a
// capability wired into one call path but not all N").
//
// The checklist, every item a source scan that FAILS today:
//
//   * the heavy-calc baseline no longer carries the keys of the readers P2.5
//     moves: the three firm ones the phase row names (`recentDayDiagnostics`,
//     `HealthExporter._decode`, `AppState._maybeNotifyRecoveryReady`, each with
//     every rule that listed it) and the keys of the readers it also moves
//     (`sleepWindows`, `ReadinessData._absentDiag`, `InvestigateData.load`);
//   * no moved reader parses or encodes a payload in its own body any more;
//   * both screens of B10 read through `getDayBlock(day, keys)`, and no file
//     under lib/ui2 names the `payload_json` column at all (the third reader of
//     the same bypass would be the finding);
//   * `HealthExporter` has no path around the store: no `LocalDb.dayResult(`,
//     no codec call, no `_decode` (its Android priority scan and its bulk loop
//     were the two call sites of one local function);
//   * `LastResultCache` neither parses nor encodes JSON itself (`read` and `put`
//     were its only two sites);
//   * `decodeJsonPayloadsHeavy` is a registered `Dispatcher.run` entry marked
//     @heavy, like `decodeDayPayloadsHeavy`;
//   * B6 is MOVED, not deleted: the scope note's open owner question (Q5, dead
//     readers) says deletion waits, and the phase row lists
//     `recentDayDiagnostics` among the readers P2.5 moves. It stays a public
//     `LocalDb` method with the same signature and its two test callers.
//
// Not decided by the design, so not pinned: where the generic lane's cache
// lives (BundleStore or its own owner) and the lane's signature.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/util/worker_entries.dart';

import '../support/dart_source.dart';

String _raw(String path) => File(path).readAsStringSync();
String _code(String path) => stripCommentsAndStrings(_raw(path));

/// The body of the function whose declaration matches [signature] (a pattern
/// that ends at the opening parenthesis of the parameter list): from the first
/// brace of the body, or to the `;` of an arrow body.
String _body(String code, Pattern signature, {String? file}) {
  final m = signature.allMatches(code).toList();
  expect(m, isNotEmpty, reason: 'declaration not found in ${file ?? 'source'}: $signature');
  var i = m.first.end - 1; // the '('
  var depth = 0;
  for (; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')' && --depth == 0) break;
  }
  final arrow = code.indexOf('=>', i);
  final brace = code.indexOf('{', i);
  if (arrow >= 0 && (brace < 0 || arrow < brace)) {
    return code.substring(arrow, code.indexOf(';', arrow));
  }
  depth = 0;
  var j = brace;
  for (; j < code.length; j++) {
    if (code[j] == '{') depth++;
    if (code[j] == '}' && --depth == 0) break;
  }
  return code.substring(brace, j + 1);
}

final _decodeCalls = RegExp(r'\b(jsonDecode|jsonEncode|decodePayloadJson|encodePayloadJson)\s*\(|\bjson\s*\.\s*(decode|encode)\s*\(|SeriesCodec\s*\.\s*(decodePayload|decodeCurve|encodePayload)\w*\s*\(');

/// `expect(code.contains(text), want)` with a short failure (a stripped source
/// file is not a useful thing to print).
void _has(String code, String text, {bool want = true, String? why}) =>
    expect(code.contains(text), want,
        reason: '${want ? 'missing' : 'unexpected'} `$text`${why == null ? '' : ': $why'}');

void main() {
  late List<Map<String, dynamic>> baseline;
  setUpAll(() {
    baseline = [
      for (final o in (jsonDecode(_raw('test/guards/heavy_calc_baseline.json'))
          as Map)['occurrences'] as List)
        (o as Map).cast<String, dynamic>(),
    ];
  });

  group('the heavy-calc baseline lost the keys of the moved readers', () {
    // symbol -> why it is in scope. Every rule that lists the symbol counts
    // (`heavyOriginOutsideHeavy` and `storedPayloadDecodeOutsideHeavy`).
    const moved = <String, String>{
      'LocalDb.recentDayDiagnostics': 'P2.5 firm (B6)',
      'HealthExporter._decode': 'P2.5 firm (B12)',
      'AppState._maybeNotifyRecoveryReady': 'P2.5 firm (B11)',
      'LocalRepositoryImpl.sleepWindows': 'P2.5, carry-over (a): 14 inline jsonDecode',
      'ReadinessData._absentDiag': 'P2.5 (B10)',
    };

    for (final e in moved.entries) {
      test('${e.key} (${e.value})', () {
        final left = [
          for (final o in baseline)
            if (o['symbol'] == e.key) '${o['rule']} ${o['element']}',
        ];
        expect(left, isEmpty);
      });
    }

    test('InvestigateData.load lost its jsonDecode key (B10)', () {
      final left = [
        for (final o in baseline)
          if (o['symbol'] == 'InvestigateData.load' &&
              o['rule'] == 'storedPayloadDecodeOutsideHeavy')
            '${o['rule']} ${o['element']}',
      ];
      expect(left, isEmpty);
    });

    test('the baseline did not grow a key for the lane or the new accessor',
        () {
      final grown = [
        for (final o in baseline)
          if ('${o['file']}'.contains('ui2/last_result_cache.dart') &&
                  o['rule'] != 'unresolvedInvocation' ||
              '${o['symbol']}'.contains('getDayBlock') ||
              '${o['symbol']}'.contains('decodeJsonPayloads'))
            '${o['rule']} ${o['file']} ${o['symbol']}',
      ];
      expect(grown, isEmpty);
    });
  });

  group('no moved reader parses or encodes a payload in its own body', () {
    final cases = <String, ({String file, Pattern signature})>{
      'LocalDb.recentDayDiagnostics': (
        file: 'lib/data/db.dart',
        signature: RegExp(r'recentDayDiagnostics\('),
      ),
      'LocalRepositoryImpl.sleepWindows': (
        file: 'lib/data/local_repository_impl.dart',
        signature: RegExp(r'sleepWindows\('),
      ),
      'LocalRepositoryImpl.getDayCalorieCurve': (
        file: 'lib/data/local_repository_impl.dart',
        signature: RegExp(r'getDayCalorieCurve\('),
      ),
      'AppState._maybeNotifyRecoveryReady': (
        file: 'lib/state/app_state.dart',
        signature: RegExp(r'_maybeNotifyRecoveryReady\(\)\s*async'),
      ),
    };

    for (final e in cases.entries) {
      test(e.key, () {
        final body = _body(_code(e.value.file), e.value.signature, file: e.value.file);

        expect(_decodeCalls.allMatches(body).map((m) => m[0]).toList(), isEmpty);
      });
    }

    test('the wake row does not use the day-bundle compatibility door', () {
      final code = _code('lib/data/local_repository_impl.dart');

      _has(_body(code, RegExp(r'_wakeFeatures\(')), 'decodeStoredPayload',
          want: false, why: 'carry-over (b): the wake row goes to the generic JSON lane');
    });
  });

  group('B10: both screens read through getDayBlock', () {
    const screens = [
      'lib/ui2/screens/readiness_detail.dart',
      'lib/ui2/screens/investigate.dart',
    ];

    for (final f in screens) {
      test(f, () {
        final code = _code(f);

        _has(code, 'getDayBlock(');
        _has(code, 'jsonDecode', want: false);
        _has(code, 'LocalDb.dayResult(', want: false,
            why: 'the whole bundle (and its payload text) to read one key');
        _has(_raw(f), 'payload_json', want: false);
      });
    }

    test('no file under lib/ui2 names the payload_json column (AGENTS 4.7: '
        'a third screen reading the bundle around the seam would be the '
        'same bug)', () {
      final hits = [
        for (final f in Directory('lib/ui2').listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart') && _raw(f.path).contains('payload_json')) f.path,
      ];

      expect(hits, isEmpty);
    });

    test('the accessor is on the repository contract the screens hold', () {
      _has(_code('lib/data/local_repository.dart'), 'getDayBlock(');
    });
  });

  group('B12: HealthExporter has no path around the store', () {
    test('no direct day_result read, no codec call, no local _decode', () {
      final code = _code('lib/health/health_export.dart');

      _has(code, 'LocalDb.dayResult(', want: false);
      _has(code, 'decodePayloadJson', want: false);
      _has(code, '_decode(', want: false,
          why: 'its two call sites (the Android priority scan and the bulk '
              'loop) both went through this one local function');
      _has(code, 'BundleStore');
    });
  });

  group('B7: LastResultCache neither parses nor encodes JSON itself', () {
    test('no jsonDecode / jsonEncode in the file (read and put were its two '
        'sites)', () {
      final code = _code('lib/ui2/last_result_cache.dart');

      expect(_decodeCalls.allMatches(code).map((m) => m[0]).toList(), isEmpty);
    });
  });

  group('the generic JSON lane is a registered worker entry', () {
    test('decodeJsonPayloadsHeavy is a Dispatcher.run row in kWorkerEntries',
        () {
      final rows = kWorkerEntries
          .where((w) => w.symbol.toString().contains('decodeJsonPayloadsHeavy'))
          .toList();

      expect(rows, hasLength(1));
      expect(rows.single.dispatcher, Dispatcher.run);
      expect(rows.single.reason, isNotEmpty);
    });

    test('it is @heavy, starts with the worker header and reports its entry',
        () {
      final defs = [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              RegExp(r'@heavy\s+[\w<>?, ]+\s+decodeJsonPayloadsHeavy\(')
                  .hasMatch(_raw(f.path)))
            f.path,
      ];
      expect(defs, hasLength(1), reason: 'one definition, marked @heavy');
      final src = _raw(defs.single);
      final body = src.substring(src.indexOf('decodeJsonPayloadsHeavy('));

      expect(body.indexOf('WorkerInit.ensure'), greaterThanOrEqualTo(0));
      expect(body.indexOf('WorkerInit.ensure'), lessThan(body.indexOf('assertWorker')));
      _has(src, "WorkerAudit.entered('decodeJsonPayloadsHeavy')");
      _has(src, 'Isolate.run');
    });
  });

  group('B6 is moved, not deleted (open owner question Q5)', () {
    test('LocalDb.recentDayDiagnostics keeps its public signature', () {
      expect(
        _code('lib/data/db.dart'),
        contains(RegExp(r'static\s+Future<List<Map<String,\s*dynamic>>>\s+'
            r'recentDayDiagnostics\(\s*int\s+limit,?\s*\)')),
      );
    });
  });
}
