import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// Finding 1 (review round 3): a suite that builds its source path in a
/// variable, from Platform.script, or in a helper function must still be
/// found. The detector reads every reachable Dart file as an AST and takes any
/// file-system read whose path is not a plain literal outside the source roots
/// for a source read.
void main() {
  late Directory root;
  void write(String path, String body) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  setUp(() {
    root = scratch('mutaudit_reads_');
    write('lib/a.dart', 'int a = 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> reasonsFor(String body, {List<String> roots = const ['lib', 'tool', 'packages', 'bin']}) {
    write('test/x_test.dart', "import 'dart:io';\nimport 'package:path/path.dart' as p;\n$body\n");
    return SourceScanDetector(root: root.path, sourceRoots: roots).reasons('test/x_test.dart');
  }

  group('read paths that escaped the regex', () {
    void flagged(String name, String body, {String? rule}) => test(name, () {
          final why = reasonsFor(body);
          expect(why, isNotEmpty, reason: body);
          expect(why.join('\n'), contains('test/x_test.dart:'), reason: 'names file and line');
          if (rule != null) expect(why.join('\n'), contains(rule));
        });

    flagged('the root is held in a constant and interpolated',
        "void main() { const dir = 'lib'; File('\$dir/a.dart').readAsStringSync(); }",
        rule: 'source-path');
    flagged('a final holding the root, joined', "void main() { final d = 'lib'; File(p.join(d, 'a.dart')).readAsStringSync(); }");
    flagged('a tool/ path built from a variable',
        "void main() { final base = 'tool'; File('\$base/x.dart').readAsStringSync(); }");
    flagged('a packages/ path built from a variable',
        "void main() { const pk = 'packages'; File(p.join(pk, 'a', 'lib', 'a.dart')).readAsStringSync(); }");
    flagged('a path relative to Platform.script',
        "void main() { File(p.join(p.dirname(Platform.script.toFilePath()), '..', 'lib', 'a.dart')).readAsStringSync(); }");
    flagged('Platform.script on its own', 'void main() { print(Platform.script); }', rule: 'Platform.script');
    flagged('a path taken from a function parameter',
        "String read(String path) => File(path).readAsStringSync();\nvoid main() { read('x'); }",
        rule: 'not a compile-time string literal');
    flagged('a path computed by a call', "String where() => 'li' + 'b';\nvoid main() { File(where()).readAsStringSync(); }");
    flagged('a Directory listed from a non-literal',
        'void main(List<String> a) { Directory(a.first).listSync(recursive: true); }');
    flagged('the package root listed', "void main() { Directory('.').listSync(recursive: true); }");
    flagged('the parent of the package root', "void main() { Directory('..').listSync(); }");
    flagged('Directory.current listed', 'void main() { Directory.current.listSync(); }');
    flagged('a Link', "void main() { Link(p.join('lib', 'x')).resolveSymbolicLinksSync(); }");
    flagged('File.fromUri', 'void main(Uri u) { File.fromUri(u).readAsStringSync(); }');
    flagged('new File with an interpolated path', r"void main(String d) { new File('$d/a.dart').readAsStringSync(); }");
    flagged('a prefixed io.File', "import 'dart:io' as io;\nvoid main(String d) { io.File(d).readAsStringSync(); }");
    flagged('a read on a receiver that is not a File(...) construction',
        'void main(dynamic e) { e.readAsStringSync(); e.readAsLinesSync(); }',
        rule: 'readAsStringSync');
    flagged('openRead', 'void main(dynamic e) { e.openRead(); }');
    flagged('list on an unknown receiver', 'void main(dynamic e) { e.list(); }');
    flagged('a tear-off of the constructor', 'void main(List<String> a) { a.map(File.new).toList(); }');
    flagged('a typedef for File', "typedef F = File;\nvoid main(String d) { F(d); }");
    flagged('a literal source path through a constant', "const path = 'lib/state/app_state.dart';\nvoid main() { File(path).readAsStringSync(); }");
    flagged('an absolute path that goes through lib',
        "void main() { File('/home/u/repo/lib/a.dart').readAsStringSync(); }");
    flagged('a path with dot segments that normalises into lib',
        "void main() { File('test/../lib/a.dart').readAsStringSync(); }");
    flagged('a source literal handed to a helper', "void scan(String p) {}\nvoid main() { scan('lib/a.dart'); }",
        rule: 'source-path');
    flagged('a join that starts at a source root', "void main() { final x = p.join('lib', 'a.dart'); print(x); }");
    flagged('a file with syntax errors cannot be checked', 'void main( {{{');
  });

  group('reads that are not source reads', () {
    void clean(String name, String body) => test(name, () => expect(reasonsFor(body), isEmpty, reason: body));

    clean('a literal fixture', "void main() { File('test/fixtures/x.json').readAsStringSync(); }");
    clean('a fixture through a constant', "const f = 'test/fixtures/x.json';\nvoid main() { File(f).readAsStringSync(); }");
    clean('a fixture through join', "void main() { File(p.join('test', 'fixtures', 'x.json')).readAsStringSync(); }");
    clean('a path in /tmp', "void main() { File('/tmp/x.txt').readAsStringSync(); }");
    clean('pubspec.yaml at the root', "void main() { File('pubspec.yaml').readAsStringSync(); }");
    clean('a Directory of fixtures', "void main() { Directory('test/fixtures').listSync(); }");
    clean('a File held in a variable, built from a literal fixture',
        "void main() { final f = File('test/fixtures/x.json'); f.readAsStringSync(); }");
    clean('a source path only inside a comment', "// File('lib/a.dart')\nvoid main() {}");
    clean('Directory.current without a read', 'void main() { print(Directory.current.path); }');
    clean('a string that merely contains lib/', "void main() { print('see the lib/ folder'); }");
    clean('a library name that is not a root', "void main() { File('test/library/x.json').readAsStringSync(); }");
  });

  group('the report names the site', () {
    test('file, line and rule; many sites are summarised', () {
      write('test/support/h.dart', "import 'dart:io';\n\nString f(String d) =>\n    File(d).readAsStringSync();\n");
      write('test/via_test.dart', "import 'support/h.dart';\nvoid main() {}\n");
      final why = SourceScanDetector(root: root.path).reasons('test/via_test.dart');
      expect(why.single, allOf(contains('test/support/h.dart:4'), contains('File'), contains('via')));
      final many = [for (var i = 0; i < 12; i++) "  File(d$i).readAsStringSync();"].join('\n');
      write('test/many_test.dart', "import 'dart:io';\nvoid main(String d0) {\n$many\n}\n");
      final m = SourceScanDetector(root: root.path).reasons('test/many_test.dart');
      expect(m.length, lessThan(8));
      expect(m.join('\n'), contains('more'));
    });
  });
}
