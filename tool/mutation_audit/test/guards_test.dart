import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

void main() {
  late Directory root;
  setUp(() => root = scratch('mutaudit_guards_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String body) =>
      File(p.join(root.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync(body);

  SourceScanDetector detector({List<String> roots = const ['lib'], List<String>? scanners}) => SourceScanDetector(
      root: root.path, sourceRoots: roots, scannerGlobs: scanners ?? defaultScannerGlobs);

  group('SourceScanDetector: one fixture suite per rule', () {
    setUp(() {
      write('lib/a.dart', 'int a = 1;\n');
      write('test/support/dart_source.dart', '// the shared scanner\nString codeOnly(String s) => s;\n');
      write('test/support/dart_source_lexical.dart', '// the lexical variant\n');
      write('test/support/helper_reads.dart', "import 'dart:io';\nString src() => File('lib/a.dart').readAsStringSync();\n");
      write('test/support/helper_plain.dart', 'int plain() => 1;\n');
      write('test/support/chain.dart', "import 'helper_reads.dart';\n");
    });

    test('a runtime suite has no reasons', () {
      write('test/runtime_test.dart', "import 'package:test/test.dart';\nimport 'package:demo/a.dart';\nimport 'support/helper_plain.dart';\nvoid main() { test('t', () { expect(a, 1); }); }\n");
      expect(detector().reasons('test/runtime_test.dart'), isEmpty);
    });

    test('rule b: it imports a shared source scanner (relative import)', () {
      write('test/scan_test.dart', "import 'support/dart_source.dart';\nvoid main() {}\n");
      final why = detector().reasons('test/scan_test.dart');
      expect(why, hasLength(1));
      expect(why.single, allOf(contains('source scanner'), contains('test/support/dart_source.dart')));
    });

    test('rule b: the lexical scanner too, and one in a sub directory suite', () {
      write('test/deep/x/scan_test.dart', "import '../../support/dart_source_lexical.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/deep/x/scan_test.dart').single, contains('dart_source_lexical.dart'));
    });

    test('rule b: through a chain of helpers', () {
      write('test/support/mid.dart', "export 'dart_source.dart';\n");
      write('test/chain_scan_test.dart', "import 'support/mid.dart';\nvoid main() {}\n");
      final why = detector().reasons('test/chain_scan_test.dart');
      expect(why.join(' '), contains('test/support/dart_source.dart'));
      expect(why.join(' '), contains('test/support/mid.dart'));
    });

    test('rule b: extra scanners can be named by glob', () {
      write('test/support/my_grep.dart', '// a scanner by another name\n');
      write('test/grep_test.dart', "import 'support/my_grep.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/grep_test.dart'), isEmpty);
      expect(detector(scanners: ['test/support/my_grep.dart']).reasons('test/grep_test.dart'), isNotEmpty);
    });

    group('rule c: it reads files under lib/', () {
      void reads(String name, String line) {
        test(name, () {
          write('test/c_test.dart', "import 'dart:io';\nimport 'package:path/path.dart' as p;\nvoid main() {\n  $line\n}\n");
          final why = detector().reasons('test/c_test.dart');
          expect(why, isNotEmpty, reason: line);
          expect(why.join(' '), contains('lib'));
        });
      }

      reads('File with a lib path', "final s = File('lib/a.dart').readAsStringSync();");
      reads('Directory listing of lib', "final d = Directory('lib/ui2').listSync(recursive: true);");
      reads('the bare lib directory', "Directory('lib').listSync();");
      reads('p.join starting at lib', "File(p.join('lib', 'src', 'a.dart')).readAsStringSync();");
      reads('a relative prefix', "File('../lib/a.dart').readAsStringSync();");
      reads('a path held in a constant', "const path = 'lib/state/app_state.dart'; File(path).readAsStringSync();");
      reads('double quotes', 'File("lib/a.dart").readAsStringSync();');
      reads('an interpolated root', r"File('${Directory.current.path}/lib/a.dart').readAsStringSync();");
    });

    test('rule c through an imported helper: the helper is named', () {
      write('test/via_test.dart', "import 'support/helper_reads.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/via_test.dart').join(' '), contains('test/support/helper_reads.dart'));
      write('test/via2_test.dart', "import 'support/chain.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/via2_test.dart').join(' '), contains('helper_reads.dart'));
    });

    test('importing code from lib/ is not reading it', () {
      write('test/pkg_test.dart', "import 'package:demo/lib_thing.dart';\nimport '../lib/a.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/pkg_test.dart'), isEmpty);
    });

    test('other source roots: the directory of a mutated file counts as source', () {
      write('scripts/tool.dart', 'void main() {}\n');
      write('test/scripts_test.dart', "import 'dart:io';\nvoid main() { File('scripts/tool.dart').readAsStringSync(); }\n");
      expect(detector().reasons('test/scripts_test.dart'), isEmpty);
      expect(detector(roots: ['lib', 'scripts']).reasons('test/scripts_test.dart'), isNotEmpty);
    });

    test('tool/, packages/ and bin/ are source roots whatever is mutated', () {
      for (final d in ['tool', 'packages', 'bin']) {
        write('test/${d}_test.dart', "import 'dart:io';\nvoid main() { File('$d/x.dart').readAsStringSync(); }\n");
        expect(detector().reasons('test/${d}_test.dart'), isNotEmpty, reason: d);
      }
    });

    test('a suite that cannot be read is treated as a scanner (nothing can be checked)', () {
      final why = detector().reasons('test/not_there_test.dart');
      expect(why.single, contains('cannot be checked'));
    });

    test('an absolute suite path outside the export cannot be checked either', () {
      expect(detector().reasons('/elsewhere/x_test.dart'), isNotEmpty);
    });

    test('an import cycle terminates', () {
      write('test/support/c1.dart', "import 'c2.dart';\n");
      write('test/support/c2.dart', "import 'c1.dart';\n");
      write('test/cyc_test.dart', "import 'support/c1.dart';\nvoid main() {}\n");
      expect(detector().reasons('test/cyc_test.dart'), isEmpty);
    });

    test('results are stable between calls', () {
      write('test/scan_test.dart', "import 'support/dart_source.dart';\nvoid main() {}\n");
      final d = detector();
      expect(d.reasons('test/scan_test.dart'), d.reasons('test/scan_test.dart'));
    });
  });

  group('RuntimeAllowlist', () {
    TestOutcome at(String suite, String name) =>
        TestOutcome(suite: suite, name: name, result: TestResult.failure, skipped: false);

    test('a suite line allows every test of the suite, and only that suite', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart  # pumps the widget\n');
      expect(a.allows(at('test/a_test.dart', 'anything')), isTrue);
      expect(a.allows(at('test/b_test.dart', 'anything')), isFalse);
    });

    test('a suite::name line allows that test only', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart::group runtime one  # runs the engine\n');
      expect(a.allows(at('test/a_test.dart', 'group runtime one')), isTrue);
      expect(a.allows(at('test/a_test.dart', 'group another')), isFalse);
      expect(a.allows(at('test/b_test.dart', 'group runtime one')), isFalse);
    });

    test('names may contain colons and spaces; the first :: separates', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart::parses a::b and c: d  # runtime\n');
      expect(a.allows(at('test/a_test.dart', 'parses a::b and c: d')), isTrue);
    });

    test('every entry needs a reason: "path  # reason"', () {
      for (final bad in [
        'test/a_test.dart\n',
        'test/a_test.dart::one test\n',
        'test/a_test.dart #\n',
        'test/a_test.dart  #   \n',
        'test/a_test.dart#reason\n',
      ]) {
        expect(() => RuntimeAllowlist.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('the format error names the line', () {
      expect(() => RuntimeAllowlist.parse('# ok\ntest/a_test.dart  # fine\ntest/b_test.dart\n'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains('line 3'), contains('test/b_test.dart')))));
    });

    test('the reason is kept with its entry', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart  # pumps the widget\ntest/b_test.dart::n  # runs the codec\n');
      expect([for (final e in a.entries) (e.key, e.reason)],
          [('test/a_test.dart', 'pumps the widget'), ('test/b_test.dart::n', 'runs the codec')]);
      expect([for (final e in a.entries) e.suite], ['test/a_test.dart', 'test/b_test.dart']);
    });

    test('comments, blank lines, CRLF and surrounding whitespace are ignored', () {
      final a = RuntimeAllowlist.parse('# reviewed 2026-10-09 by me\r\n\r\n  test/a_test.dart   # why  \r\n   # another\n');
      expect(a.length, 1);
      expect(a.entries.single.reason, 'why');
      expect(a.allows(at('test/a_test.dart', 'x')), isTrue);
    });

    test('a hash inside a test name is not the reason separator', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart::issue #12 regression  # real engine\n');
      expect(a.allows(at('test/a_test.dart', 'issue #12 regression')), isTrue);
      expect(a.entries.single.reason, 'real engine');
    });

    test('empty text allows nothing', () {
      expect(RuntimeAllowlist.parse('').allows(at('test/a_test.dart', 'x')), isFalse);
      expect(RuntimeAllowlist.parse('').length, 0);
    });

    test('suite names are matched exactly (no prefix, no glob)', () {
      final a = RuntimeAllowlist.parse('test/a_test.dart  # r\ntest/*.dart  # r\n');
      expect(a.allows(at('test/a_test.dart.bak', 'x')), isFalse);
      expect(a.allows(at('test/b_test.dart', 'x')), isFalse);
    });
  });

  group('GuardMatcher with detection and the allowlist', () {
    TestOutcome at(String suite, [String name = 'n']) =>
        TestOutcome(suite: suite, name: name, result: TestResult.failure, skipped: false);

    setUp(() {
      write('lib/a.dart', 'int a = 1;\n');
      write('test/scan_test.dart', "import 'dart:io';\nvoid main() { File('lib/a.dart').readAsStringSync(); }\n");
      write('test/runtime_test.dart', "import 'package:test/test.dart';\nvoid main() {}\n");
    });

    test('a detected scanner is a guard even with no pattern', () {
      final g = GuardMatcher(const [], detector: SourceScanDetector(root: root.path));
      expect(g.matches(at('test/scan_test.dart')), isTrue);
      expect(g.reasons(at('test/scan_test.dart')).single, contains('lib'));
      expect(g.matches(at('test/runtime_test.dart')), isFalse);
    });

    test('pattern and detection reasons are both given', () {
      final g = GuardMatcher(['test/scan_test.dart'], detector: SourceScanDetector(root: root.path));
      final why = g.reasons(at('test/scan_test.dart'));
      expect(why, hasLength(2));
      expect(why.first, contains('matches guard pattern test/scan_test.dart'));
    });

    test('the allowlist turns a whole detected suite into runtime', () {
      final g = GuardMatcher(const [],
          detector: SourceScanDetector(root: root.path), allowlist: RuntimeAllowlist.parse('test/scan_test.dart  # runs code'));
      expect(g.matches(at('test/scan_test.dart')), isFalse);
    });

    test('a per-test allowlist entry frees that test; the rest of the suite stays a guard', () {
      final g = GuardMatcher(const [],
          detector: SourceScanDetector(root: root.path),
          allowlist: RuntimeAllowlist.parse('test/scan_test.dart::the runtime one  # runs code'));
      expect(g.matches(at('test/scan_test.dart', 'the runtime one')), isFalse);
      expect(g.matches(at('test/scan_test.dart', 'greps source')), isTrue);
    });

    test('the allowlist overrides patterns as well', () {
      final g = GuardMatcher(['test/guards/**'], allowlist: RuntimeAllowlist.parse('test/guards/x_test.dart  # runs code'));
      expect(g.matches(at('test/guards/x_test.dart')), isFalse);
      expect(g.matches(at('test/guards/y_test.dart')), isTrue);
    });
  });

  group('expandTestSelectors', () {
    setUp(() {
      for (final f in [
        'test/a_test.dart',
        'test/sub/b_test.dart',
        'test/sub/deep/c_test.dart',
        'test/support/helper.dart',
        'test/notes.md',
        'integration_test/i_test.dart',
        'lib/x_test.dart',
      ]) {
        write(f, '// $f\n');
      }
    });

    test('no selector means the test directory: every *_test.dart, sorted, helpers left out', () {
      expect(expandTestSelectors(root.path, const []),
          ['test/a_test.dart', 'test/sub/b_test.dart', 'test/sub/deep/c_test.dart']);
    });

    test('`test` as a directory is the whole suite, not a subset', () {
      expect(expandTestSelectors(root.path, ['test']), expandTestSelectors(root.path, const []));
      expect(expandTestSelectors(root.path, ['test/']), expandTestSelectors(root.path, const []));
      expect(expandTestSelectors(root.path, ['.']), contains('integration_test/i_test.dart'));
    });

    test('a directory, a file, a glob and an absolute path', () {
      expect(expandTestSelectors(root.path, ['test/sub']), ['test/sub/b_test.dart', 'test/sub/deep/c_test.dart']);
      expect(expandTestSelectors(root.path, ['test/a_test.dart']), ['test/a_test.dart']);
      expect(expandTestSelectors(root.path, ['test/**/c_test.dart']), ['test/sub/deep/c_test.dart']);
      expect(expandTestSelectors(root.path, [p.join(root.path, 'test/sub/b_test.dart')]), ['test/sub/b_test.dart']);
    });

    test('several selectors merge without duplicates', () {
      expect(expandTestSelectors(root.path, ['test/sub', 'test/sub/b_test.dart', 'test/a_test.dart']),
          ['test/a_test.dart', 'test/sub/b_test.dart', 'test/sub/deep/c_test.dart']);
    });

    test('a selector that matches nothing is refused', () {
      expect(() => expandTestSelectors(root.path, ['test/nope']), throwsFormatException);
      expect(() => expandTestSelectors(root.path, ['test/*_zzz.dart']), throwsFormatException);
    });
  });
}
