// file_size_guard_test.dart — no .dart file under lib/ or test/ may exceed
// 6,000 CODE lines (owner rule A). Engine: support/file_size.dart; the counter
// is support/code_lines.dart. Fixture tests run the engine over a temp tree with
// a tiny limit; the last group is the real repo check.
//
// Red today: test/guards/file_size_exceptions.json does not exist, and
// lib/data/db.dart and lib/compute/derivation_engine.dart are over the limit.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/file_size.dart';

const _limit = 10;
const _slack = 3;

void main() {
  group('fixture trees (limit 10, slack 3)', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('file_size_'));
    tearDown(() => root.deleteSync(recursive: true));

    /// Writes [codeLines] lines of code (plus noise that must not count).
    void put(String rel, int codeLines, {String noise = ''}) {
      final f = File('${root.path}/$rel')..createSync(recursive: true);
      f.writeAsStringSync(
        '${List.generate(codeLines, (i) => 'int v$i = $i;').join('\n')}\n$noise',
      );
    }

    List<String> run(Map<String, int> exceptions) => fileSizeProblems(
          root: root.path,
          exceptions: exceptions,
          limit: _limit,
          slack: _slack,
        );

    test('files at or under the limit pass', () {
      put('lib/a.dart', _limit);
      put('test/b_test.dart', 1);
      expect(run({}), isEmpty);
    });

    test('a file over the limit that is not listed fails and names itself', () {
      put('lib/big.dart', _limit + 1);
      final problems = run({});
      expect(problems, hasLength(1));
      expect(problems.single, contains('lib/big.dart'));
      expect(problems.single, contains('${_limit + 1}'));
    });

    test('test/ is scanned too', () {
      put('test/big_test.dart', _limit + 1);
      final problems = run({});
      expect(problems.single, contains('test/big_test.dart'));
    });

    test('blank lines and comments do not count toward the limit', () {
      put(
        'lib/commented.dart',
        _limit,
        noise: '\n\n// c\n/// d\n/* e\n f */\n${'// pad\n' * 50}\n\n',
      );
      expect(run({}), isEmpty);
    });

    test('a multi-line non-SQL string does not count; an SQL one does', () {
      final prose = List.filled(40, 'free text').join('\n');
      File('${root.path}/lib/prose.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync("const s = '''\n$prose\n''';\n");
      expect(run({}), isEmpty, reason: 'only the two delimiter lines count');

      final sql = List.filled(40, 'SELECT 1').join('\n');
      File('${root.path}/lib/sql.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync("const s = '''\n$sql\n''';\n");
      expect(run({}).single, contains('lib/sql.dart'));
    });

    test('generated files are excluded entirely', () {
      put('lib/l10n/app_localizations.dart', _limit * 3);
      put('lib/l10n/app_localizations_de.dart', _limit * 3);
      put('lib/model.g.dart', _limit * 3);
      put('lib/deep/dir/model.freezed.dart', _limit * 3);
      put('test/support/thing.g.dart', _limit * 3);
      expect(run({}), isEmpty);
    });

    test('lib/l10n files that are not app_localizations*.dart are scanned', () {
      put('lib/l10n/helper.dart', _limit + 1);
      expect(run({}).single, contains('lib/l10n/helper.dart'));
    });

    test('non-dart files and files outside lib/ and test/ are ignored', () {
      put('tool/big.dart', _limit * 3);
      put('integration_test/big.dart', _limit * 3);
      put('lib/notes.txt', _limit * 3);
      put('lib/data.json', _limit * 3);
      expect(run({}), isEmpty);
    });

    test('an excepted file passes up to recorded + slack, and fails past it',
        () {
      const recorded = 20;
      put('lib/big.dart', recorded);
      expect(run({'lib/big.dart': recorded}), isEmpty);

      put('lib/big.dart', recorded + _slack);
      expect(run({'lib/big.dart': recorded}), isEmpty,
          reason: 'recorded + slack is allowed');

      put('lib/big.dart', recorded + _slack + 1);
      final problems = run({'lib/big.dart': recorded});
      expect(problems, hasLength(1));
      expect(problems.single, contains('lib/big.dart'));
      expect(problems.single, contains('${recorded + _slack + 1}'));
    });

    test('an excepted file that shrank but is still over the limit passes', () {
      put('lib/big.dart', _limit + 5);
      expect(run({'lib/big.dart': _limit + 50}), isEmpty);
    });

    test('a listed file now under the limit fails: remove it from the list',
        () {
      put('lib/was_big.dart', _limit - 1);
      final problems = run({'lib/was_big.dart': _limit + 40});
      expect(problems, hasLength(1));
      expect(problems.single, contains('lib/was_big.dart'));
      expect(problems.single, contains('remove it from the list'));
    });

    test('a listed path that no longer exists fails', () {
      put('lib/other.dart', 1);
      final problems = run({'lib/gone.dart': _limit + 40});
      expect(problems, hasLength(1));
      expect(problems.single, contains('lib/gone.dart'));
      expect(problems.single, contains('exist'));
    });

    test('an exception does not cover a different file', () {
      put('lib/a.dart', _limit + 1);
      put('lib/b.dart', _limit + 1);
      final problems = run({'lib/a.dart': _limit + 1});
      expect(problems, hasLength(1));
      expect(problems.single, contains('lib/b.dart'));
    });

    test('several problems are all reported', () {
      put('lib/new_big.dart', _limit + 1);
      put('lib/small.dart', 1);
      final problems = run({
        'lib/small.dart': _limit + 9,
        'lib/missing.dart': _limit + 9,
      });
      expect(problems, hasLength(3));
    });
  });

  group('the real repo (limit 6,000 code lines, slack 200)', () {
    const path = 'test/guards/file_size_exceptions.json';

    test('limits are the owner\'s numbers', () {
      expect(kMaxCodeLines, 6000);
      expect(kExceptionSlack, 200);
    });

    test('file_size_exceptions.json exists and is a flat path -> int map', () {
      expect(File(path).existsSync(), isTrue,
          reason: '$path records every file over $kMaxCodeLines code lines');
      final map = readFileSizeExceptions(path);
      for (final e in map.entries) {
        expect(e.value, greaterThan(kMaxCodeLines),
            reason: '${e.key}: only files over the limit belong in the list');
        expect(e.key, matches(RegExp('^(lib|test)/')), reason: e.key);
      }
    });

    test('no file is over the limit unlisted, over its record + slack, or '
        'listed while small or gone', () {
      final exceptions = File(path).existsSync()
          ? readFileSizeExceptions(path)
          : <String, int>{};
      expect(fileSizeProblems(root: '.', exceptions: exceptions), isEmpty);
    });
  });
}
