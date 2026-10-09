import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

Mutant mutantOf(String source, String original, String mutated,
    {String file = 'lib/a.dart', int occurrence = 0}) {
  var at = -1;
  for (var i = 0; i <= occurrence; i++) {
    at = source.indexOf(original, at + 1);
  }
  final byteOffset = utf8.encode(source.substring(0, at)).length;
  return Mutant(
    id: '$file:$byteOffset:relational:00000000',
    file: file,
    line: 1,
    column: 1,
    byteOffset: byteOffset,
    byteLength: utf8.encode(original).length,
    operator: MutationOperator.relational,
    original: original,
    mutated: mutated,
  );
}

void main() {
  late Directory root;
  late File target;
  late File neighbour;
  const text = 'bool f(int a, int b) => a < b;\nbool g(int a) => a > 0;\n';

  setUp(() {
    root = scratch('mutaudit_apply_');
    target = File(p.join(root.path, 'lib/a.dart'))..createSync(recursive: true);
    target.writeAsStringSync(text);
    neighbour = File(p.join(root.path, 'lib/b.dart'))..writeAsStringSync('int x = 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('apply changes exactly the bytes of the site', () async {
    final applier = MutationApplier(root.path);
    final applied = await applier.apply(mutantOf(text, '<', '<='));
    expect(target.readAsStringSync(), text.replaceFirst('a < b', 'a <= b'));
    expect(neighbour.readAsStringSync(), 'int x = 1;\n');
    await applier.restore(applied);
  });

  test('restore puts the original bytes back', () async {
    final applier = MutationApplier(root.path);
    final before = target.readAsBytesSync();
    final applied = await applier.apply(mutantOf(text, '>', '>='));
    expect(target.readAsBytesSync(), isNot(before));
    await applier.restore(applied);
    expect(target.readAsBytesSync(), before);
  });

  test('restore is safe to call twice', () async {
    final applier = MutationApplier(root.path);
    final before = target.readAsBytesSync();
    final applied = await applier.apply(mutantOf(text, '<', '<='));
    await applier.restore(applied);
    await applier.restore(applied);
    expect(target.readAsBytesSync(), before);
  });

  test('restore wins over whatever the test run did to the file meanwhile', () async {
    final applier = MutationApplier(root.path);
    final before = target.readAsBytesSync();
    final applied = await applier.apply(mutantOf(text, '<', '<='));
    target.writeAsStringSync('garbage');
    await applier.restore(applied);
    expect(target.readAsBytesSync(), before);
  });

  test('offsets are bytes: a file with multi-byte text, a BOM and CRLF round-trips', () async {
    const src = 'é☃ // café\r\nbool f(int a, int b) => a < b;\r\n';
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(src)];
    target.writeAsBytesSync(bytes);
    final applier = MutationApplier(root.path);
    final m = mutantOf(src, '<', '<=');
    final applied = await applier.apply(Mutant(
      id: m.id,
      file: m.file,
      line: m.line,
      column: m.column,
      byteOffset: m.byteOffset + 3, // the BOM is part of the file
      byteLength: m.byteLength,
      operator: m.operator,
      original: m.original,
      mutated: m.mutated,
    ));
    final mutated = target.readAsBytesSync();
    expect(mutated.length, bytes.length + 1);
    expect(utf8.decode(mutated.sublist(3)), src.replaceFirst('a < b', 'a <= b'));
    await applier.restore(applied);
    expect(target.readAsBytesSync(), bytes);
  });

  test('a mutant whose original text is not at the offset is refused, file untouched', () async {
    final applier = MutationApplier(root.path);
    target.writeAsStringSync('// moved\n$text');
    final before = target.readAsBytesSync();
    await expectLater(applier.apply(mutantOf(text, '<', '<=')), throwsA(isA<StaleMutantError>()));
    expect(target.readAsBytesSync(), before);
  });

  test('an offset past the end of the file is refused', () async {
    final applier = MutationApplier(root.path);
    final m = Mutant(
        id: 'x',
        file: 'lib/a.dart',
        line: 1,
        column: 1,
        byteOffset: 99999,
        byteLength: 1,
        operator: MutationOperator.relational,
        original: '<',
        mutated: '<=');
    await expectLater(applier.apply(m), throwsA(isA<StaleMutantError>()));
  });

  test('applying the same mutant twice without a restore is refused', () async {
    final applier = MutationApplier(root.path);
    final m = mutantOf(text, '<', '<=');
    final applied = await applier.apply(m);
    await expectLater(applier.apply(m), throwsA(isA<StaleMutantError>()));
    await applier.restore(applied);
  });

  test('a path outside the root is refused', () async {
    final applier = MutationApplier(root.path);
    for (final bad in ['../outside.dart', '/etc/passwd', 'lib/../../x.dart']) {
      final m = mutantOf(text, '<', '<=', file: bad);
      await expectLater(applier.apply(m), throwsArgumentError, reason: bad);
    }
  });

  test('a missing file is refused', () async {
    final applier = MutationApplier(root.path);
    await expectLater(applier.apply(mutantOf(text, '<', '<=', file: 'lib/missing.dart')), throwsA(anything));
  });
}
