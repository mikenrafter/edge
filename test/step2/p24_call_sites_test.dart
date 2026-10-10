// P2.4 call sites (design 02 step 2, B14; AGENTS.md 4.7 "a capability wired
// into one call path but not all N").
//
// B14: `Substrate.fromJson` runs on the UI isolate for every substrate a
// prepare worker returns (`DerivationEngine`, the `kind == 'substrate'` branch
// of the worker listener; up to three loads per derived day). P2.4 turns that
// into `Substrate.fromTransfer`. The checklist:
//
//   * the worker-result branch adopts through fromTransfer, and still books
//     its `substrate_adopt_*` perf counters around the call;
//   * every other `Substrate.fromJson` caller in lib/ is listed below with the
//     reason it is not a worker transfer; the list only shrinks;
//   * `fromTransfer` has no caller outside the engine's worker branch (a
//     persisted or user-supplied map must keep the validating fromJson);
//   * the worker still sends the typed columns through `Isolate.exit` (the
//     adoption only helps if they cross as typed lists);
//   * `substrate.dart` introduces no narrowed typed list (no Int32List).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// lib/ files (relative) that may still call `Substrate.fromJson`, the count,
/// and why. Shrink-only: a listed file that stops calling must be deleted from
/// here (and the count lowered).
///
/// `derive_prepare.dart`: `PreparedDerivationDay.fromJson` (3 substrate
/// rebuilds: day_sub, sleep_sub, nap_sub) is the JSON mirror of `toJson` for
/// the `prepared_day` worker mode. Nothing in lib/ reads that mode back: the
/// engine's listener handles only `kind == 'substrate'`, and its own ponytail
/// note records that `PreparedDerivationDay.fromJson` has no caller outside the
/// file. It is a dead-by-design round trip, not the B14 path, so it keeps the
/// validating conversion. If a caller appears, it should use fromTransfer and
/// this entry goes.
const Map<String, ({int count, String why})> _fromJsonCallers = {
  'compute/derive_prepare.dart': (
    count: 3,
    why: 'PreparedDerivationDay.fromJson: the prepared_day mirror of toJson; '
        'no production reader, not the substrate worker transfer',
  ),
};

String _raw(String path) => File(path).readAsStringSync();
String _code(String path) => stripCommentsAndStrings(_raw(path));

Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _rel(File f) => f.path.substring('lib/'.length);

/// The engine's worker-result branch: from `kind == 'substrate'` to the
/// completer call. (Located in the raw text, read from the stripped text: the
/// stripper keeps every offset.)
({String raw, String code}) _workerBranch() {
  const path = 'lib/compute/derivation_engine.dart';
  final raw = _raw(path), code = _code(path);
  final at = raw.indexOf("kind == 'substrate'");
  expect(at, greaterThanOrEqualTo(0),
      reason: 'the worker listener branch moved: update this test');
  final end = raw.indexOf('result.complete(', at);
  expect(end, greaterThan(at));
  return (raw: raw.substring(at, end), code: code.substring(at, end));
}

void main() {
  group('the worker-result path adopts through fromTransfer', () {
    test('the kind == substrate branch calls Substrate.fromTransfer and not '
        'Substrate.fromJson', () {
      final b = _workerBranch();

      expect(b.code, contains('Substrate.fromTransfer('));
      expect(b.code, isNot(contains('Substrate.fromJson')));
    });

    test('derivation_engine.dart has no Substrate.fromJson left', () {
      final code = _code('lib/compute/derivation_engine.dart');

      expect(RegExp(r'Substrate\.fromJson\b').hasMatch(code), isFalse,
          reason: 'every prepare-worker substrate is rebuilt in the one '
              'branch above');
      expect(RegExp(r'Substrate\.fromTransfer\(').allMatches(code).length, 1,
          reason: 'one adoption site: a second would be a second path');
    });

    test('the branch still books substrate_adopt_* around the adoption '
        '(P2.0a counters)', () {
      final b = _workerBranch();

      expect(b.raw, contains("'substrate_adopt_\$label'"));
      expect(b.raw, contains("'substrate_adopt_samples_\$label'"));
      expect(b.raw, contains('adopted.length'));
      expect(b.raw.indexOf('Substrate.fromTransfer('),
          greaterThan(b.raw.indexOf('adoptStartedAt')),
          reason: 'the clock starts before the adoption');
    });
  });

  group('source checklist (lib/)', () {
    test('only the listed files call Substrate.fromJson, with the listed '
        'counts', () {
      final found = <String, int>{};
      for (final f in _libFiles()) {
        final n = RegExp(r'Substrate\.fromJson\b').allMatches(_code(f.path)).length;
        if (n > 0) found[_rel(f)] = n;
      }

      for (final e in found.entries) {
        expect(_fromJsonCallers.containsKey(e.key), isTrue,
            reason: '${e.key} calls Substrate.fromJson ${e.value}x: if it '
                'rebuilds a prepare-worker substrate, use fromTransfer; if '
                'not, list it in _fromJsonCallers with the reason');
        expect(e.value, _fromJsonCallers[e.key]!.count, reason: e.key);
      }
      expect(_fromJsonCallers.keys.toSet().difference(found.keys.toSet()),
          isEmpty,
          reason: 'delete these entries from _fromJsonCallers (shrink-only)');
    });

    test('Substrate.fromTransfer has no caller outside the engine worker '
        'branch', () {
      final callers = <String>{};
      for (final f in _libFiles()) {
        if (RegExp(r'\.fromTransfer\b').hasMatch(_code(f.path))) {
          callers.add(_rel(f));
        }
      }

      expect(callers, {'compute/derivation_engine.dart'},
          reason: 'a persisted or user-supplied map needs the validating '
              'fromJson; add a caller only with a test that its map is a '
              'worker transfer');
    });

    test('Substrate.fromJson itself stays (persisted maps, '
        'PreparedDerivationDay, the round-trip tests)', () {
      final code = _code('lib/compute/substrate.dart');

      expect(code, contains('static Substrate fromJson('));
      expect(code, contains('static Substrate fromTransfer('));
    });

    test('the worker still sends the substrate map through Isolate.exit '
        '(typed columns cross as typed lists)', () {
      final raw = _raw('lib/compute/derive_prepare.dart');
      final at = raw.indexOf("if (mode == 'substrate')");
      expect(at, greaterThanOrEqualTo(0));
      final end = raw.indexOf('} else {', at);
      final branch = stripCommentsAndStrings(raw).substring(at, end);

      expect(branch, contains('Isolate.exit('));
      expect(raw.substring(at, end), contains("'payload': substrate.toJson()"));
    });

    test('substrate.dart creates no narrowed typed list (no Int32List and '
        'friends); integers stay List<int>', () {
      final code = _code('lib/compute/substrate.dart');

      expect(
        RegExp(r'\b(Int8List|Int16List|Int32List|Uint8List|Uint16List|'
                r'Uint32List|Float32List)\b')
            .hasMatch(code),
        isFalse,
        reason: 'the int columns are deliberately not narrowed '
            '(silent-truncation edge): 4.6',
      );
      expect(code, contains('Float64List'));
    });
  });
}
