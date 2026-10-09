import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// Finding 2 (review round 3): the import graph followed only one plain
/// `import '...';` per line. It must follow every URI of every import, export
/// and part, conditional ones included, `package:` URIs of the audited package
/// (they resolve to lib/), path dependencies inside the export, and helpers
/// under the source roots.
void main() {
  late Directory root;
  void write(String path, String body) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  setUp(() {
    root = scratch('mutaudit_imports_');
    write('pubspec.yaml', 'name: demo\nenvironment:\n  sdk: ^3.5.0\n');
    write('lib/a.dart', 'int a = 1;\n');
    write('test/support/reader.dart', "import 'dart:io';\nString src() => File('lib/a.dart').readAsStringSync();\n");
    write('test/support/plain.dart', 'int plain() => 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> why(String body) {
    write('test/x_test.dart', '$body\nvoid main() {}\n');
    return SourceScanDetector(root: root.path).reasons('test/x_test.dart');
  }

  group('directives are read from the AST', () {
    test('a conditional import: the default URI is plain, the configured one reads source', () {
      expect(why("import 'support/plain.dart' if (dart.library.io) 'support/reader.dart';"), isNotEmpty);
    });

    test('a conditional import: a later configuration reads source', () {
      expect(
          why("import 'support/plain.dart' if (dart.library.html) 'support/plain.dart' if (dart.library.io) 'support/reader.dart';"),
          isNotEmpty);
    });

    test('a conditional export in a helper', () {
      write('test/support/mid.dart', "export 'plain.dart' if (dart.library.io) 'reader.dart';\n");
      expect(why("import 'support/mid.dart';"), isNotEmpty);
    });

    test('two directives on one line', () {
      expect(why("import 'support/plain.dart'; import 'support/reader.dart';"), isNotEmpty);
    });

    test('a directive that spans lines and has show / hide / as', () {
      expect(why("import 'support/reader.dart'\n    as r\n    show src;"), isNotEmpty);
    });

    test('a part directive is followed', () {
      write('test/support/host.dart', "part 'reader_part.dart';\n");
      write('test/support/reader_part.dart', "part of 'host.dart';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import 'support/host.dart';"), isNotEmpty);
    });

    test('a URI inside a comment or a string is not a directive', () {
      expect(why("// import 'support/reader.dart';\nconst s = \"import 'support/reader.dart';\";"), isEmpty);
    });

    test('a plain import stays clean', () {
      expect(why("import 'support/plain.dart';"), isEmpty);
    });
  });

  group('package: URIs and helpers under the source roots', () {
    test('package:<this package>/... resolves to lib/ and is inspected', () {
      write('lib/testing/reader.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      final r = why("import 'package:demo/testing/reader.dart';");
      expect(r, isNotEmpty);
      expect(r.join(' '), contains('lib/testing/reader.dart'));
    });

    test('package:<this package>/... is followed through a conditional URI too', () {
      write('lib/testing/reader.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import 'support/plain.dart' if (dart.library.io) 'package:demo/testing/reader.dart';"), isNotEmpty);
    });

    test('a relative import into lib/ is followed', () {
      write('lib/testing/reader.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import '../lib/testing/reader.dart';"), isNotEmpty);
    });

    test('a helper under tool/ is followed', () {
      write('tool/h.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import '../tool/h.dart';"), isNotEmpty);
    });

    test('lib/ code that reads source is found through package: from a lib/ chain', () {
      write('lib/one.dart', "import 'package:demo/two.dart';\n");
      write('lib/two.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import 'package:demo/one.dart';"), isNotEmpty);
    });

    test('lib/ code that reads nothing keeps the suite a runtime suite', () {
      write('lib/pure.dart', "import 'dart:convert';\nint f(int x) => x + 1;\n");
      expect(why("import 'package:demo/pure.dart';\nimport 'package:test/test.dart';"), isEmpty);
    });

    test('a path dependency inside the export is followed', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  helper:\n    path: packages/helper\n');
      write('packages/helper/pubspec.yaml', 'name: helper\n');
      write('packages/helper/lib/h.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import 'package:helper/h.dart';"), isNotEmpty);
    });

    test('a path dependency from dependency_overrides and dev_dependencies is followed', () {
      write('pubspec.yaml',
          'name: demo\ndev_dependencies:\n  h1:\n    path: packages/h1\ndependency_overrides:\n  h2:\n    path: packages/h2\n');
      for (final n in ['h1', 'h2']) {
        write('packages/$n/lib/h.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
        expect(why("import 'package:$n/h.dart';"), isNotEmpty, reason: n);
      }
    });

    test('a package that is not in the export is ignored (hosted, git, outside path)', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  away:\n    path: ../away\n  other: ^1.0.0\n');
      expect(why("import 'package:away/h.dart';\nimport 'package:other/o.dart';\nimport 'package:test/test.dart';"), isEmpty);
    });

    test('a package: URI whose file is missing is ignored', () {
      expect(why("import 'package:demo/missing.dart';"), isEmpty);
    });

    test('no pubspec: package: URIs are ignored', () {
      File(p.join(root.path, 'pubspec.yaml')).deleteSync();
      write('lib/testing/reader.dart', "import 'dart:io';\nString s() => File('lib/a.dart').readAsStringSync();\n");
      expect(why("import 'package:demo/testing/reader.dart';"), isEmpty);
    });
  });
}
