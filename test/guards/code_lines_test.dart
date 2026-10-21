// code_lines_test.dart — fixtures for the file-size counter (owner rule A).
// Counter: test/guards/support/code_lines.dart. Red until it is implemented.

import 'package:flutter_test/flutter_test.dart';

import 'support/code_lines.dart';

void main() {
  group('blank lines and comments do not count', () {
    test('empty and whitespace-only sources are 0', () {
      expect(countCodeLines(''), 0);
      expect(countCodeLines('\n\n  \n\t\n'), 0);
    });

    test('a code line counts once; a trailing newline adds nothing', () {
      expect(countCodeLines('int a = 1;'), 1);
      expect(countCodeLines('int a = 1;\n'), 1);
      expect(countCodeLines('int a = 1;\r\nint b = 2;\r\n'), 2);
    });

    test('line, doc and indented comments are 0', () {
      expect(
        countCodeLines('// one\n/// two\n    // three\n\t/// four\n'),
        0,
      );
    });

    test('a block comment on one line, or over many, is 0', () {
      expect(countCodeLines('/* one */\n'), 0);
      expect(countCodeLines('/* start\n   middle\n   end */\n'), 0);
      expect(countCodeLines('/**\n * doc\n */\n'), 0);
    });

    test('block comments nest', () {
      expect(countCodeLines('/* a /* b */ still comment */\n'), 0);
      expect(
        countCodeLines('/* a\n/* b */\nstill comment\n*/\nint x = 1;\n'),
        1,
        reason: 'only the line after the outer */ is code',
      );
    });

    test('code followed by a trailing comment counts as code', () {
      expect(countCodeLines('int a = 1; // note\n'), 1);
      expect(countCodeLines('int a = 1; /// note\n'), 1);
      expect(countCodeLines('int a = 1; /* note */\n'), 1);
    });

    test('code before or after a block comment on the same line counts', () {
      expect(countCodeLines('/* a */ int a = 1;\n'), 1);
      expect(countCodeLines('/* a\nb */ int a = 1;\n'), 1,
          reason: 'the opener line is comment-only; the closing line has code');
      expect(countCodeLines('int a = 1; /* a\nb\nc */\n'), 1,
          reason: 'the opener line has code; the rest is comment');
    });

    test('an apostrophe or quote inside a comment does not open a string', () {
      expect(countCodeLines("// it's a comment\nint a = 1;\n"), 1);
      expect(countCodeLines('/* "unterminated\n   \'\'\' */\nint a = 1;\n'), 1);
    });

    test('a block opener inside a line comment does not start a block', () {
      expect(countCodeLines('// not /* a block\nint a = 1;\nint b = 2;\n'), 2);
    });

    test('comment markers inside a single-line string are text', () {
      expect(countCodeLines("final u = 'http://example.com';\n"), 1);
      expect(
        countCodeLines("final a = '/* not a comment */';\nfinal b = 1;\n"),
        2,
      );
      expect(countCodeLines('final a = "// x";\nfinal b = 1;\n'), 2);
    });
  });

  group('single-line strings', () {
    test('escaped quotes do not end the string early', () {
      expect(countCodeLines("final a = 'it\\'s // fine';\nfinal b = 1;\n"), 2);
      expect(countCodeLines('final a = "say \\"hi\\" // x";\nfinal b = 1;\n'), 2);
    });

    test('the other quote kind inside a string is text', () {
      expect(countCodeLines('final a = "it\'s // x";\nfinal b = 1;\n'), 2);
      expect(countCodeLines("final a = 'say \"//\" now';\nfinal b = 1;\n"), 2);
    });

    test('a raw string ends at its first closing quote, backslash or not', () {
      expect(countCodeLines("final a = r'C:\\dir\\';\nfinal b = 1;\n"), 2);
    });

    test('interpolation with nested quotes does not end the string', () {
      expect(
        countCodeLines("final a = 'x \${m['k']} // y';\nfinal b = 1;\n"),
        2,
      );
      expect(
        countCodeLines("final a = 'x \${f('a', \"b\")} /* y';\nfinal b = 1;\n"),
        2,
        reason: 'the /* is inside the string, so it opens no block comment',
      );
    });
  });

  group('multi-line strings that are not SQL are excluded', () {
    test('interior lines drop; the opening and closing lines count', () {
      const src = "final t = '''\n"
          'hello\n'
          'world\n'
          "''';\n";
      expect(countCodeLines(src), 2);
    });

    test('a comment-looking interior line is text and adds nothing', () {
      const src = "final t = '''\n"
          '// not a comment\n'
          '/* nor this\n'
          'more\n'
          "''';\n"
          'final after = 1;\n';
      expect(countCodeLines(src), 3,
          reason: 'open + close + the line after; the /* never opens a block');
    });

    test('a double-quoted triple string, holding single quotes and \'\'\'', () {
      const src = 'final t = """\n'
          "it's ''' fine\n"
          'still text\n'
          '""";\n';
      expect(countCodeLines(src), 2);
    });

    test('interpolation inside a multi-line string, with quotes of its kind',
        () {
      const src = "final t = '''\n"
          "line \${x['a']} still string\n"
          '// not a comment here\n'
          'more\n'
          "''';\n"
          'final after = 1;\n';
      expect(countCodeLines(src), 3);
    });

    test('a raw triple string: a backslash does not escape the closer', () {
      const src = "final p = r'''\n"
          "x\\''';\n"
          'final q = 1;\n';
      expect(countCodeLines(src), 3,
          reason: 'the closer on line 2 ends the string; a non-raw lexer '
              'would swallow line 3');
    });

    test('text after the opener on the same line is still the opening line',
        () {
      const src = "final t = '''first\n"
          'second\n'
          "third''';\n";
      expect(countCodeLines(src), 2);
    });

    test('words that merely contain a keyword are not SQL', () {
      const src = "final t = '''\n"
          'selection updated deleted created altered dropdown without\n'
          'withdraw withheld pragmatic\n'
          "''';\n";
      expect(countCodeLines(src), 2,
          reason: 'whole-word match only: none of these is SQL');
    });

    test('a blank interior line of a non-SQL string adds nothing', () {
      expect(countCodeLines("final t = '''\n\n\n''';\n"), 2);
    });
  });

  group('multi-line strings that contain SQL are counted', () {
    test('every line counts, case-insensitively', () {
      const src = "const q = '''\n"
          '  SELECT a\n'
          '  FROM t\n'
          "''';\n";
      expect(countCodeLines(src), 4);
      const lower = "const q = '''\n"
          '  select a\n'
          '  from t\n'
          "''';\n";
      expect(countCodeLines(lower), 4);
    });

    test('each of the nine keywords makes the string SQL', () {
      for (final kw in [
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'ALTER', //
        'DROP', 'WITH', 'PRAGMA',
      ]) {
        final src = "const q = '''\n"
            '  $kw x\n'
            '  more\n'
            "''';\n";
        expect(countCodeLines(src), 4, reason: kw);
      }
    });

    test('blank interior lines of an SQL string still do not count', () {
      const src = "const q = '''\n"
          '  SELECT a\n'
          '\n'
          '  FROM t\n'
          "''';\n";
      expect(countCodeLines(src), 4,
          reason: 'blank lines never count, SQL or not');
    });

    test('a double-quoted SQL string with interpolation counts', () {
      const src = 'final q = """\n'
          '  INSERT INTO \${table}\n'
          '  VALUES (1)\n'
          '""";\n';
      expect(countCodeLines(src), 4);
    });

    test('a raw SQL string counts', () {
      const src = "const q = r'''\n"
          '  PRAGMA journal_mode\n'
          "''';\n";
      expect(countCodeLines(src), 3);
    });

    test('the keyword rule is the string\'s whole text, not one line', () {
      const src = "const q = '''\n"
          'first line is prose\n'
          'second line is prose\n'
          'delete from t\n'
          "''';\n";
      expect(countCodeLines(src), 5);
    });

    test('prose that uses the word "with" is SQL by the owner\'s rule', () {
      const src = "final t = '''\n"
          'come with me\n'
          "''';\n";
      expect(countCodeLines(src), 3);
    });
  });

  group('mixed source', () {
    test('a realistic file', () {
      const src = '// header\n' // 0
          '\n' // 0
          "import 'dart:io';\n" // 1
          '\n' // 0
          '/// Doc.\n' // 0
          'class A {\n' // 1
          '  final x = 1; // trailing\n' // 1
          '  /* block\n' // 0
          '     more */\n' // 0
          "  static const t = '''\n" // 1
          '    free text\n' // 0
          "  ''';\n" // 1
          '  static const q = """\n' // 1
          '    SELECT 1\n' // 1
          '  """;\n' // 1
          '}\n'; // 1
      expect(countCodeLines(src), 9);
    });
  });
}
