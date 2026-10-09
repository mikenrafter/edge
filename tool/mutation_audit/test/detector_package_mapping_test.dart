import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';
import 'support/package_config.dart';

/// Sol r6 #2: the pubspec-derived guess `package:demo` -> `lib/` used to win
/// over the prepared `.dart_tool/package_config.json`, so the detector could
/// read lib/h.dart while `package:demo/h.dart` actually runs src/h.dart. The
/// resolved package config is authoritative; when it is missing or cannot map
/// a package the pubspec says is in the export, importing that package is
/// scanning evidence (`package-mapping`).
void main() {
  late Directory root;
  void write(String path, String body) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  setUp(() {
    root = scratch('mutaudit_mapping_');
    write('pubspec.yaml', 'name: demo\nenvironment:\n  sdk: ^3.5.0\n');
    write('lib/a.dart', 'int a = 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  const harmless = 'int h() => 1;\n';
  const scanner = "import 'dart:io';\nString h() => File('lib/a.dart').readAsStringSync();\n";

  List<String> why(String body) {
    write('test/x_test.dart', '$body\nvoid main() {}\n');
    return SourceScanDetector(root: root.path).reasons('test/x_test.dart');
  }

  group('the package config is authoritative', () {
    test('demo -> src/: the scanner in src/h.dart is found, the harmless lib/h.dart is not what is read', () {
      write('lib/h.dart', harmless);
      write('src/h.dart', scanner);
      writeConfig(root.path, {'demo': ('../', 'src/')});
      final r = why("import 'package:demo/h.dart';").join('\n');
      expect(r, contains('src/h.dart'));
      expect(r, contains('may read source'));
      expect(r, isNot(contains('package-mapping')), reason: 'a clear mapping is not evidence by itself');
    });

    test('the converse: demo -> lib/ (the config says so) while src/h.dart is a scanner: the suite is clean', () {
      write('lib/h.dart', harmless);
      write('src/h.dart', scanner);
      writeConfig(root.path, {'demo': ('../', 'lib/')});
      expect(why("import 'package:demo/h.dart';"), isEmpty);
    });

    test('a path dependency inside the export is mapped by the config too', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  helper:\n    path: packages/helper\n');
      write('packages/helper/lib/h.dart', harmless);
      write('packages/helper/src/h.dart', scanner);
      writeConfig(root.path, {'demo': ('../', 'lib/'), 'helper': ('../packages/helper', 'src/')});
      expect(why("import 'package:helper/h.dart';").join('\n'), contains('packages/helper/src/h.dart'));
    });

    test('a rootUri written as an absolute file: URI inside the export works', () {
      write('src/h.dart', scanner);
      writeConfig(root.path, {'demo': ('file://${root.path}/', 'src/')});
      expect(why("import 'package:demo/h.dart';").join('\n'), contains('src/h.dart'));
    });

    test('a package the config places outside the export is not part of the repository', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  away:\n    path: ../away\n');
      writeConfig(root.path, {'demo': ('../', 'lib/'), 'away': ('../../away', 'lib/')});
      expect(why("import 'package:away/h.dart';"), isEmpty);
    });
  });

  group('no usable mapping is scanning evidence (rule package-mapping)', () {
    test('there is no package config', () {
      write('lib/h.dart', harmless);
      final r = why("import 'package:demo/h.dart';");
      expect(r, hasLength(1));
      expect(r.single, allOf(contains('test/x_test.dart:1'), contains('[package-mapping]'), contains('package:demo'), contains('package_config.json')));
    });

    test('the config is not JSON', () {
      write('lib/h.dart', harmless);
      write('.dart_tool/package_config.json', '{ not json');
      expect(why("import 'package:demo/h.dart';").join('\n'), contains('[package-mapping]'));
    });

    test('the config does not list a package the pubspec places in the export', () {
      write('pubspec.yaml', 'name: demo\ndependencies:\n  helper:\n    path: packages/helper\n');
      write('packages/helper/lib/h.dart', harmless);
      writeConfig(root.path, {'demo': ('../', 'lib/')});
      expect(why("import 'package:helper/h.dart';").join('\n'), allOf(contains('[package-mapping]'), contains('helper')));
    });

    test('two entries for one package that disagree', () {
      write('lib/h.dart', harmless);
      write('src/h.dart', harmless);
      File(p.join(root.path, '.dart_tool/package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":['
            '{"name":"demo","rootUri":"../","packageUri":"lib/"},'
            '{"name":"demo","rootUri":"../","packageUri":"src/"}]}');
      expect(why("import 'package:demo/h.dart';").join('\n'), contains('[package-mapping]'));
    });

    test('an entry whose root cannot be resolved to a file location', () {
      write('lib/h.dart', harmless);
      writeConfig(root.path, {'demo': ('http://example.com/demo/', 'lib/')});
      expect(why("import 'package:demo/h.dart';").join('\n'), contains('[package-mapping]'));
    });

    test('an entry without a rootUri', () {
      write('lib/h.dart', harmless);
      File(p.join(root.path, '.dart_tool/package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[{"name":"demo","packageUri":"lib/"}]}');
      expect(why("import 'package:demo/h.dart';").join('\n'), contains('[package-mapping]'));
    });

    test('hosted and unknown packages are still not evidence', () {
      writeConfig(root.path, {'demo': ('../', 'lib/'), 'test': ('file:///home/dev/.pub-cache/hosted/pub.dev/test-1.0.0', 'lib/')});
      expect(why("import 'package:test/test.dart';\nimport 'package:stranger/x.dart';"), isEmpty);
    });

    test('the evidence is reported through a helper too, with the chain', () {
      write('test/support/mid.dart', "import 'package:demo/h.dart';\n");
      final r = why("import 'support/mid.dart';").join('\n');
      expect(r, allOf(contains('[package-mapping]'), contains('test/support/mid.dart:1'), contains('via')));
    });
  });
}
