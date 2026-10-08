// Structural guards for the sample archive (invariants 3, 9, 10, 13).
//
// "Compute never reads the archive" and "the coach cannot see it" are
// regression pins that pass today (the feature does not exist yet) and must
// keep passing. "The prune is preceded by the archive write" fails today.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';

import '../support/dart_source.dart';

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

/// Sample-related findings in one file's code (comments and strings
/// blanked), after allowing the single write-side entry point.
List<String> sampleReads(String raw) {
  final code = stripCommentsAndStrings(raw);
  final out = <String>[];
  for (final m in RegExp(r'SampleArchiver\s*\.\s*(\w+)').allMatches(code)) {
    if (m.group(1) != 'archiveBefore') out.add('SampleArchiver.${m.group(1)}');
  }
  final rest = code.replaceAll(RegExp(r'SampleArchiver\s*\.\s*archiveBefore'), '');
  for (final m in RegExp(r'\bSample(Archiver|Codec|Mode|Stats|Encoding|Header|SignalSpec|'
          r'Segment|Level|Refinement|PartSummary|Zone|Lock|Lerp|Detail|'
          r'ArchiveRow|DayStatus|Carved)\b|'
          r'\b(sampleBytes|sampleCoverage|sampleNextPart|sampleCarveRunner|'
          r'importSamplePart|carveSamplePart\w*)\b').allMatches(rest)) {
    final w = m.group(0)!;
    if (w == 'SampleArchiver') continue; // the import `show` clause
    out.add(w);
  }
  // The table named inside a SQL string (strings are blanked above).
  for (final line in raw.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('//') || t.startsWith('import ') || t.startsWith('export ')) {
      continue;
    }
    if (line.contains('spectral_archive')) out.add('table:spectral_archive');
  }
  return out;
}

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
  group('the guard itself detects what it guards', () {
    test('a decode, a table read, a reconstruct all trip it', () {
      expect(sampleReads('final d = SampleCodec.decode(b);'), isNotEmpty);
      expect(sampleReads("db.rawQuery('SELECT * FROM spectral_archive');"),
          isNotEmpty);
      expect(sampleReads('await SampleArchiver.reconstruct(d, s);'),
          contains('SampleArchiver.reconstruct'));
    });
    test('the one write-side call is allowed', () {
      expect(
          sampleReads("import '../data/sample_archive.dart' "
              "show SampleArchiver;\n"
              'await SampleArchiver.archiveBefore(c, nowSec: n);'),
          isEmpty);
    });
  });

  group('derivation never reads the archive (invariant 3: a reconstruction is '
      'an approximation)', () {
    test('no file under lib/compute names the table, the codec or any '
        'archiver reader', () {
      final bad = <String>[];
      for (final f in _dartFiles('lib/compute')) {
        final hits = sampleReads(f.readAsStringSync());
        if (hits.isNotEmpty) bad.add('${f.path}: $hits');
      }
      expect(bad, isEmpty);
    });

    test('nor does lib/coach, and the coach SQL guard refuses the table', () {
      for (final f in _dartFiles('lib/coach')) {
        expect(sampleReads(f.readAsStringSync()), isEmpty, reason: f.path);
      }
      expect(() => CoachDb.guardAndPrepare('SELECT * FROM spectral_archive'),
          throwsA(isA<SqlGuardError>()));
    });

    test('the table is created in db.dart and read only by '
        'lib/data/sample_archive.dart outside it', () {
      final readers = <String>[];
      for (final f in _dartFiles('lib')) {
        if (f.path.endsWith('lib/data/sample_archive.dart') ||
            f.path.endsWith('lib/data/sample_import.dart') ||
            f.path.endsWith('lib/data/db.dart')) {
          continue;
        }
        if (f.readAsStringSync().contains('spectral_archive')) {
          // Imports of the archiver are fine; SQL naming the table is not.
          final hit = f.readAsLinesSync().any((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') &&
                !t.startsWith('import ') &&
                l.contains('spectral_archive');
          });
          if (hit) readers.add(f.path);
        }
      }
      expect(readers, isEmpty);
    });
  });

  group('the archive is written BEFORE the raw prune (RED)', () {
    final engine = stripCommentsAndStrings(
        File('lib/compute/derivation_engine.dart').readAsStringSync());
    String bodyOf() => _body(engine, 'Future<void> _pruneOldDecoded');

    test('_pruneOldDecoded calls SampleArchiver.archiveBefore with the same '
        'cutoff, before pruneDecodedBeforeRecTs', () {
      final body = bodyOf();
      final a = body.indexOf('SampleArchiver.archiveBefore');
      final p = body.indexOf('pruneDecodedBeforeRecTs');
      expect(a, isNonNegative, reason: 'archive hook missing');
      expect(p, isNonNegative);
      expect(a, lessThan(p));
      expect(body, matches(RegExp(r'archiveBefore\(\s*cutoffSec\b')));
    });

    test('an archive failure cannot block the prune: the call sits in a '
        'try/catch (the prune enforces rawRetentionDays)', () {
      final body = bodyOf();
      expect(body,
          matches(RegExp(r'try\s*\{[^{}]*SampleArchiver\.archiveBefore[^{}]*\}\s*catch')));
    });

    test('the hook only runs after the cutoff decision (no archive when the '
        'prune is withheld for an under-derived day)', () {
      final body = bodyOf();
      final a = body.indexOf('SampleArchiver.archiveBefore');
      final guard = body.indexOf('if (cutoffSec == null) return');
      expect(guard, isNonNegative);
      expect(a, greaterThan(guard));
    });

    test('the prune is guarded by the input revision read BEFORE the archive '
        '(an offload landing mid-archive skips the prune)', () {
      final body = bodyOf();
      final rev = body.indexOf('decodedRevSumBefore');
      final a = body.indexOf('SampleArchiver.archiveBefore');
      final pr = body.indexOf('pruneDecodedBeforeRecTs');
      expect(rev, isNonNegative, reason: 'revision never read');
      expect(rev, lessThan(a));
      expect(body, matches(RegExp(r'pruneDecodedBeforeRecTs\([^)]*expectedRevSum')));
      expect(pr, greaterThan(a));
    });

    test('the only compute-layer reference is that call', () {
      final f = File('lib/compute/derivation_engine.dart').readAsStringSync();
      expect(sampleReads(f), isEmpty);
      expect(f, contains('SampleArchiver.archiveBefore'));
    });
  });
}
