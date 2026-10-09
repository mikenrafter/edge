import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// Sol r5 #3: the detector used to drop an import whose file did not exist
/// yet (a setup-generated helper) and call the suite a runtime suite. Now an
/// import that names a file the export does not have is scanning evidence
/// (`unresolved-import`), and the detection is run on the prepared tree.
void main() {
  late Directory root;
  void write(String path, String body) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  setUp(() {
    root = scratch('mutaudit_unresolved_');
    write('pubspec.yaml', 'name: demo\nenvironment:\n  sdk: ^3.5.0\n');
    write('lib/a.dart', 'int a = 1;\n');
    write('test/support/plain.dart', 'int plain() => 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  const reader = "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n";

  List<String> why(String body, {String suite = 'test/x_test.dart'}) {
    write(suite, '$body\nvoid main() {}\n');
    return SourceScanDetector(root: root.path).reasons(suite);
  }

  group('an import of a file the export does not have', () {
    test('a relative import: unresolved-import, with file:line, the URI and the reason', () {
      final r = why("import 'support/generated.dart';");
      expect(r, hasLength(1));
      expect(r.single, allOf(contains('test/x_test.dart:1'), contains('[unresolved-import]'), contains('support/generated.dart')));
      expect(r.single, contains('not in the export'));
    });

    test('package:<this package>/... of a missing file', () {
      expect(why("import 'package:demo/gen/l10n.dart';").join(' '), contains('[unresolved-import]'));
    });

    test('package:<path dependency inside the export>/... of a missing file', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  helper:\n    path: packages/helper\n');
      write('packages/helper/pubspec.yaml', 'name: helper\n');
      expect(why("import 'package:helper/missing.dart';").join(' '), contains('[unresolved-import]'));
    });

    test('export and part directives count too', () {
      expect(why("export 'support/generated.dart';").join(' '), contains('[unresolved-import]'));
      write('test/support/host.dart', "part 'host.g.dart';\n");
      expect(why("import 'support/host.dart';").join(' '), allOf(contains('[unresolved-import]'), contains('host.g.dart')));
    });

    test('every URI of a conditional directive is checked', () {
      expect(why("import 'support/plain.dart' if (dart.library.io) 'support/io_impl.dart';").join(' '), contains('io_impl.dart'));
    });

    test('a relative import that leaves the export cannot be checked either', () {
      expect(why("import '../../outside/helper.dart';").join(' '), contains('[unresolved-import]'));
    });

    test('found through a helper: the reason names the chain', () {
      write('test/support/mid.dart', "import 'gen.dart';\n");
      final r = why("import 'support/mid.dart';").join(' ');
      expect(r, allOf(contains('[unresolved-import]'), contains('test/support/mid.dart:1'), contains('via')));
    });

    test('in a file under lib/ that a test reaches', () {
      write('lib/uses_gen.dart', "import 'gen/strings.dart';\n");
      expect(why("import 'package:demo/uses_gen.dart';").join(' '), contains('lib/uses_gen.dart:1'));
    });
  });

  group('what is still ignored: not part of the repository', () {
    test('dart:, hosted and git packages, packages that are not in the export, other schemes', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  away:\n    path: ../away\n  other: ^1.0.0\n');
      expect(
          why("import 'dart:async';\nimport 'package:test/test.dart';\nimport 'package:other/o.dart';\nimport 'package:away/a.dart';"),
          isEmpty);
    });

    test('a plain import of a file that exists stays clean', () {
      expect(why("import 'support/plain.dart';"), isEmpty);
    });
  });

  group('detection on the prepared tree', () {
    test('a helper that setup generates is read once it exists, and its scanner is found', () {
      write('test/gen_test.dart', "import 'support/generated.dart';\nvoid main() {}\n");
      final before = SourceScanDetector(root: root.path).reasons('test/gen_test.dart');
      expect(before.join(' '), contains('[unresolved-import]'), reason: 'unknown before setup: scanning evidence, not a clean pass');
      write('test/support/generated.dart', reader);
      final after = SourceScanDetector(root: root.path).reasons('test/gen_test.dart');
      expect(after.join(' '), contains('may read source'));
      expect(after.join(' '), contains('test/support/generated.dart'));
      expect(after.join(' '), isNot(contains('unresolved-import')));
    });

    test('a package that only the package config names (inside the export) is followed', () {
      write('.dart_tool/package_config.json', jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'gen_pkg', 'rootUri': '../generated/gen_pkg', 'packageUri': 'src/'},
          {'name': 'demo', 'rootUri': '../', 'packageUri': 'lib/'},
        ],
      }));
      write('generated/gen_pkg/src/h.dart', reader);
      final r = why("import 'package:gen_pkg/h.dart';").join(' ');
      expect(r, contains('may read source'));
      expect(r, contains('generated/gen_pkg/src/h.dart'));
      expect(why("import 'package:gen_pkg/missing.dart';", suite: 'test/y_test.dart').join(' '), contains('[unresolved-import]'));
    });
  });
}
