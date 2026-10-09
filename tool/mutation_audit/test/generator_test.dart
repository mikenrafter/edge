import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

List<Mutant> gen(String source, {String file = 'lib/a.dart'}) =>
    generateMutants(source, file: file);

List<Mutant> only(String source, MutationOperator op) =>
    gen(source).where((m) => m.operator == op).toList();

/// "original -> mutated" of every mutant of [op].
List<String> changes(String source, MutationOperator op) =>
    [for (final m in only(source, op)) '${m.original} -> ${m.mutated}'];

void expectParses(String source) {
  final r = parseString(content: source, throwIfDiagnostics: false);
  expect(r.errors, isEmpty, reason: 'mutated source must still parse:\n$source');
}

void main() {
  group('relational operators', () {
    const pairs = {
      '<': '<=',
      '<=': '<',
      '>': '>=',
      '>=': '>',
      '==': '!=',
      '!=': '==',
    };
    for (final e in pairs.entries) {
      test('${e.key} becomes ${e.value}, once', () {
        final src = 'bool f(int a, int b) => a ${e.key} b;\n';
        expect(changes(src, MutationOperator.relational), ['${e.key} -> ${e.value}']);
        final m = only(src, MutationOperator.relational).single;
        expect(mutatedSource(src, m), 'bool f(int a, int b) => a ${e.value} b;\n');
        expectParses(mutatedSource(src, m));
      });
    }

    test('other binary operators, shifts, generics and arrows are left alone', () {
      const src = '''
List<int> f(int a, int b) {
  final xs = <List<int>>[];
  final c = a + b - a * b ~/ 2 % 3 << 1 >> 1;
  return xs.isEmpty ? [c] : [];
}
''';
      expect(only(src, MutationOperator.relational), isEmpty);
    });

    test('every comparison in a chain is its own site', () {
      const src = 'bool f(int a, int b, int c) => a < b && b <= c || a == c;\n';
      expect(changes(src, MutationOperator.relational), ['< -> <=', '<= -> <', '== -> !=']);
    });
  });

  group('integer literals in comparisons', () {
    test('a literal operand gets +1 and -1', () {
      const src = 'bool f(int x) => x < 10;\n';
      expect(changes(src, MutationOperator.intLiteral), unorderedEquals(['10 -> 9', '10 -> 11']));
      final plus = only(src, MutationOperator.intLiteral).firstWhere((m) => m.mutated == '11');
      expect(mutatedSource(src, plus), 'bool f(int x) => x < 11;\n');
    });

    test('on either side, for every comparison operator', () {
      for (final op in ['<', '<=', '>', '>=', '==', '!=']) {
        expect(changes('bool f(int x) => 7 $op x;\n', MutationOperator.intLiteral), ['7 -> 6', '7 -> 8'],
            reason: op);
        expect(changes('bool f(int x) => x $op 7;\n', MutationOperator.intLiteral), ['7 -> 6', '7 -> 8'],
            reason: op);
      }
    });

    test('parentheses are looked through', () {
      expect(changes('bool f(int x) => x < (3);\n', MutationOperator.intLiteral), ['3 -> 2', '3 -> 4']);
    });

    test('zero minus one is written -1 and still parses', () {
      const src = 'bool f(int x) => x >= 0;\n';
      final m = only(src, MutationOperator.intLiteral).firstWhere((m) => m.mutated == '-1');
      expect(mutatedSource(src, m), 'bool f(int x) => x >= -1;\n');
      expectParses(mutatedSource(src, m));
    });

    test('+1 on the largest 64-bit literal would wrap: only -1 is produced', () {
      const src = 'bool f(int x) => x < 9223372036854775807;\n';
      expect(changes(src, MutationOperator.intLiteral), ['9223372036854775807 -> 9223372036854775806']);
    });

    test('every produced literal is exactly the original +-1, never a wrapped value', () {
      const src = 'bool f(int x) => x < 9223372036854775807 || x > 9223372036854775806 || x == 0;\n';
      for (final m in only(src, MutationOperator.intLiteral)) {
        final diff = (BigInt.parse(m.mutated) - BigInt.parse(m.original)).abs();
        expect(diff, BigInt.one, reason: '${m.original} -> ${m.mutated}');
        expect(BigInt.parse(m.mutated) >= BigInt.from(-1), isTrue);
        expect(BigInt.parse(m.mutated) <= BigInt.parse('9223372036854775807'), isTrue);
      }
    });

    test('the smallest 64-bit literal (a unary minus on 2^63) and a literal beyond 64 bits are left alone', () {
      expect(only('bool f(int x) => x > -9223372036854775808;\n', MutationOperator.intLiteral), isEmpty);
      expect(only('bool f(double x) => x < 9223372036854775808;\n', MutationOperator.intLiteral), isEmpty);
    });

    test('literals that are not direct operands of a comparison are left alone', () {
      const src = '''
int f(int x, List<int> xs) {
  final a = x + 10;
  final b = xs[3];
  final c = x < 1 + 2 ? 4 : 5;
  final d = x < -1;
  g(7);
  return a + b + c;
}
void g(int n) {}
''';
      // `x < 1 + 2`: 1 and 2 are operands of +, `-1` is a unary minus, not a literal operand.
      expect(only(src, MutationOperator.intLiteral), isEmpty);
    });

    test('double and hexadecimal literals are left alone', () {
      expect(only('bool f(double x) => x < 1.5;\n', MutationOperator.intLiteral), isEmpty);
      expect(only('bool f(int x) => x < 0x10;\n', MutationOperator.intLiteral), isEmpty);
    });
  });

  group('condition negation', () {
    test('if', () {
      const src = 'void f(bool a) {\n  if (a) {}\n}\n';
      final m = only(src, MutationOperator.negateCondition).single;
      expect((m.original, m.mutated), ('a', '!(a)'));
      expect(mutatedSource(src, m), 'void f(bool a) {\n  if (!(a)) {}\n}\n');
    });

    test('else-if chains give one site per condition', () {
      const src = 'void f(bool a, bool b) {\n  if (a) {} else if (b) {}\n}\n';
      expect(changes(src, MutationOperator.negateCondition), ['a -> !(a)', 'b -> !(b)']);
    });

    test('while and ternary', () {
      const src = 'int f(bool a, bool b) {\n  while (a) {}\n  return b ? 1 : 2;\n}\n';
      expect(changes(src, MutationOperator.negateCondition), ['a -> !(a)', 'b -> !(b)']);
    });

    test('a compound condition is wrapped whole', () {
      const src = 'void f(int a, int b) {\n  if (a < b || b == 0) {}\n}\n';
      final m = only(src, MutationOperator.negateCondition).single;
      expect(m.mutated, '!(a < b || b == 0)');
      expectParses(mutatedSource(src, m));
    });

    test('do-while, for and collection ifs are not negated', () {
      const src = '''
List<int> f(bool a) {
  do {} while (a);
  for (var i = 0; a; i++) {}
  return [if (a) 1];
}
''';
      expect(only(src, MutationOperator.negateCondition), isEmpty);
    });
  });

  group('logical operators', () {
    test('&& becomes || and back', () {
      expect(changes('bool f(bool a, bool b) => a && b;\n', MutationOperator.logical), ['&& -> ||']);
      expect(changes('bool f(bool a, bool b) => a || b;\n', MutationOperator.logical), ['|| -> &&']);
    });

    test('each operator of a chain is a site', () {
      expect(changes('bool f(bool a, bool b, bool c) => a && b || c;\n', MutationOperator.logical),
          ['&& -> ||', '|| -> &&']);
    });
  });

  group('early-return removal', () {
    test('a return directly under an if-branch becomes an empty statement', () {
      const src = 'int f(int x) {\n  if (x < 0) return -1;\n  return x;\n}\n';
      final m = only(src, MutationOperator.removeReturn).single;
      expect((m.original, m.mutated), ('return -1;', ';'));
      expect(mutatedSource(src, m), 'int f(int x) {\n  if (x < 0) ;\n  return x;\n}\n');
      expectParses(mutatedSource(src, m));
    });

    test('in a block, bare returns included', () {
      const src = 'void f(bool a) {\n  if (a) {\n    g();\n    return;\n  }\n  g();\n}\nvoid g() {}\n';
      final m = only(src, MutationOperator.removeReturn).single;
      expect((m.original, m.mutated), ('return;', ';'));
      expectParses(mutatedSource(src, m));
    });

    test('else-branches count too', () {
      const src = 'int f(bool a) {\n  if (a) {\n    g();\n  } else {\n    return 2;\n  }\n  return 1;\n}\nvoid g() {}\n';
      expect(changes(src, MutationOperator.removeReturn), ['return 2; -> ;']);
    });

    test('a return that ends the function is not removed', () {
      expect(only('int f(int x) {\n  return x;\n}\n', MutationOperator.removeReturn), isEmpty);
      // An if that is the last statement: nothing follows, so removing the
      // return would change what the function is, not an early exit.
      expect(only('int f(bool a) {\n  if (a) return 1; else return 2;\n}\n', MutationOperator.removeReturn),
          isEmpty);
    });

    test('a return nested deeper than the branch itself is not removed', () {
      const src = 'int f(bool a) {\n  if (a) {\n    {\n      return 1;\n    }\n  }\n  return 2;\n}\n';
      expect(only(src, MutationOperator.removeReturn), isEmpty);
    });

    test('a return inside a closure in the branch belongs to the closure', () {
      const src = 'void f(bool a, List<int> xs) {\n  if (a) {\n    xs.forEach((x) {\n      if (x < 0) return;\n      g();\n    });\n  }\n  g();\n}\nvoid g() {}\n';
      // Only the inner `if (x < 0) return;` has a statement after it in its block.
      expect(changes(src, MutationOperator.removeReturn), ['return; -> ;']);
    });
  });

  group('what is never mutated', () {
    test('comments', () {
      const src = '''
// if (a < b && c == 1) return 1;
/* a || b > 2 */
/// docs: x >= 3 ? 1 : 2
bool f(int a) => true;
''';
      expect(gen(src), isEmpty);
    });

    test('string literals, interpolations and adjacent strings included', () {
      const src = r'''
String f(int a, int b) {
  final x = 'a < b && b == 1';
  final y = "if (a) return 1; ${a < b} $a";
  final z = r'a >= 2' 'a != 3';
  final w = """
    a > b
  """;
  return x + y + z + w;
}
''';
      expect(gen(src), isEmpty);
    });

    test('import, export and part directives (conditional ones too) and annotations', () {
      const src = '''
import 'package:a/a.dart' if (dart.library.io == 'true') 'package:a/io.dart';
export 'package:b/b.dart' if (dart.library.html == 'true') 'package:b/html.dart';
part 'a.g.dart';

@A(1 < 2 && true)
class K {
  @A(3 > 2)
  final int v;
  const K(this.v);
}

class A {
  const A(this.ok);
  final bool ok;
}
''';
      expect(gen(src), isEmpty);
    });

    test('code next to excluded text is still mutated', () {
      const src = "// a < b\nbool f(int a, int b) => a < b; // c > d\n";
      expect(changes(src, MutationOperator.relational), ['< -> <=']);
    });

    test('source that does not parse yields nothing', () {
      expect(gen('bool f(int a, int b) => a < ;;; ((\n'), isEmpty);
    });
  });

  group('mutant records', () {
    const src = '// café ☃\nbool f(int a, int b) =>\n    a < b;\n';

    test('line and column are 1-based, at the replaced text', () {
      final m = only(src, MutationOperator.relational).single;
      expect((m.line, m.column), (3, 7));
      expect(m.file, 'lib/a.dart');
    });

    test('the byte offset counts UTF-8 bytes, not characters', () {
      final m = only(src, MutationOperator.relational).single;
      final bytes = utf8.encode(src);
      expect(utf8.decode(bytes.sublist(m.byteOffset, m.byteOffset + m.byteLength)), m.original);
      // The `<` is two characters after `a`; the e-acute (2 bytes) and the snowman
      // (3 bytes) before it add 1 + 2 bytes over their character count.
      expect(m.byteOffset, src.indexOf('a < b') + 2 + 3);
    });

    test('original is the exact text at the site for every mutant', () {
      const many = '''
bool f(int a, int b, bool c) {
  if (a < 10 && b >= 0 || c) return a == b;
  while (c) { c = !c; }
  return c ? a > 1 : b != 2;
}
''';
      final bytes = utf8.encode(many);
      final all = gen(many);
      expect(all, isNotEmpty);
      for (final m in all) {
        expect(utf8.decode(bytes.sublist(m.byteOffset, m.byteOffset + m.byteLength)), m.original, reason: '$m');
        expectParses(mutatedSource(many, m));
        expect(m.mutated, isNot(m.original));
      }
    });

    test('mutantId: file, byte offset, operator and a hash of the replacement', () {
      expect(mutantId(file: 'lib/a.dart', byteOffset: 12, operator: MutationOperator.relational, mutated: '<='),
          'lib/a.dart:12:relational:94f721b2');
      expect(mutantId(file: 'lib/a.dart', byteOffset: 12, operator: MutationOperator.intLiteral, mutated: '9'),
          'lib/a.dart:12:int-literal:3c0cb3b4');
      expect(mutantId(file: 'x.dart', byteOffset: 0, operator: MutationOperator.logical, mutated: '||'),
          'x.dart:0:logical:5558edc5');
    });

    test('generated ids follow that format, are unique and stable', () {
      const many = 'bool f(int a, int b) => a < 10 && b > 0;\n';
      final first = gen(many), second = gen(many);
      expect([for (final m in first) m.id], [for (final m in second) m.id]);
      expect({for (final m in first) m.id}.length, first.length);
      for (final m in first) {
        expect(m.id, matches(RegExp(r'^lib/a\.dart:\d+:[a-z-]+:[0-9a-f]{8}$')));
        expect(m.id,
            mutantId(file: m.file, byteOffset: m.byteOffset, operator: m.operator, mutated: m.mutated));
      }
    });

    test('the file name is part of the id', () {
      const s = 'bool f(int a) => a < 1;\n';
      expect(gen(s, file: 'lib/a.dart').first.id, isNot(gen(s, file: 'lib/b.dart').first.id));
    });

    test('order: ascending byte offset, then operator id, then replacement', () {
      const many = '''
bool f(int a, int b) {
  if (a < 10 && b > 0) return true;
  return a == 3 ? b != 4 : false;
}
''';
      final all = gen(many);
      final sorted = [...all]..sort((x, y) {
          final byOffset = x.byteOffset.compareTo(y.byteOffset);
          if (byOffset != 0) return byOffset;
          final byOp = x.operator.id.compareTo(y.operator.id);
          return byOp != 0 ? byOp : x.mutated.compareTo(y.mutated);
        });
      expect([for (final m in all) m.id], [for (final m in sorted) m.id]);
    });

    test('operators are reported by their documented ids', () {
      expect(MutationOperator.values.map((o) => o.id),
          ['relational', 'int-literal', 'negate-condition', 'logical', 'remove-return']);
    });

    test('toJson carries every field', () {
      final m = only('bool f(int a) => a < 1;\n', MutationOperator.relational).single;
      expect(m.toJson(), {
        'id': m.id,
        'file': 'lib/a.dart',
        'line': 1,
        'column': 20,
        'byteOffset': m.byteOffset,
        'byteLength': 1,
        'operator': 'relational',
        'original': '<',
        'mutated': '<=',
      });
    });
  });
}
