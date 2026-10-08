// fixture_world.dart — materialises the synthetic fixture packages under
// test/guards/fixtures/ into a temp directory so package:analyzer can resolve
// them.
//
// Layout on disk (checked in):
//   fixtures/_packages/<pkg>/lib/**.dart.fixture   shared stub packages
//   fixtures/<case>/lib/**.dart.fixture            the fixture app's lib/
//   fixtures/<case>/test/**.dart.fixture           its test/ (sendable_<entry>_test)
//
// Why `.dart.fixture`: the sources are deliberately wrong Dart as far as the
// guard is concerned (and some are not even clean under flutter_lints), so they
// must not be picked up by `flutter analyze` or `flutter test`. Materialisation
// strips the `.fixture` suffix.
//
// Every case becomes its own package `fixture_app` with a package_config that
// maps: fixture_app -> the case, openstrap_edge -> THIS repo (the real
// util/heavy.dart, worker_entries.dart, raw_readers.dart markers), and the
// shared stubs openstrap_analytics / fixture_dispatch.

import 'dart:convert';
import 'dart:io';

import 'heavy_guard.dart';

class FixtureWorld {
  final Directory root;
  final String repoRoot;
  final List<String> cases;
  FixtureWorld._(this.root, this.repoRoot, this.cases);

  /// The repo root: tests run with the package root as the working directory.
  static String get repoRootPath => Directory.current.path;

  static Directory get fixturesDir =>
      Directory('${Directory.current.path}/test/guards/fixtures');

  /// Copies everything once. Call from `setUpAll`; [dispose] from `tearDownAll`.
  static Future<FixtureWorld> materialize() async {
    final out = await Directory.systemTemp.createTemp('heavy_guard_world_');
    final repo = repoRootPath;
    final src = fixturesDir;
    final cases = <String>[];

    for (final entry in src.listSync().whereType<Directory>()) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final isPackages = name == '_packages';
      await _copyTree(entry, Directory('${out.path}/$name'));
      if (isPackages) {
        for (final pkg in Directory('${out.path}/_packages')
            .listSync()
            .whereType<Directory>()) {
          final pkgName = pkg.uri.pathSegments.where((s) => s.isNotEmpty).last;
          _writePackage(pkg.path, pkgName, out.path, repo, isApp: false);
        }
      } else {
        cases.add(name);
        _writePackage('${out.path}/$name', 'fixture_app', out.path, repo,
            isApp: true);
      }
    }
    cases.sort();
    return FixtureWorld._(out, repo, cases);
  }

  Future<void> dispose() => root.delete(recursive: true);

  String casePath(String name) {
    if (!cases.contains(name)) {
      throw ArgumentError('no fixture case "$name" (have ${cases.length})');
    }
    return '${root.path}/$name';
  }

  /// The merged guard config for [name].
  HeavyGuardConfig configFor(String name) =>
      HeavyGuardConfig.fixture(casePath(name));

  /// Runs the guard over one case.
  Future<HeavyGuardResult> analyze(String name) =>
      analyzeHeavyGuard(configFor(name));

  /// Reads a materialised fixture file (for the line-number-stability test).
  String read(String name, String relPath) =>
      File('${casePath(name)}/$relPath').readAsStringSync();

  void write(String name, String relPath, String contents) =>
      File('${casePath(name)}/$relPath').writeAsStringSync(contents);

  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      var rel = e.path.substring(from.path.length + 1);
      if (rel.endsWith('.dart.fixture')) {
        rel = rel.substring(0, rel.length - '.fixture'.length);
      }
      final dest = File('${to.path}/$rel');
      await dest.parent.create(recursive: true);
      await e.copy(dest.path);
    }
  }

  static void _writePackage(
    String pkgDir,
    String name,
    String worldRoot,
    String repo, {
    required bool isApp,
  }) {
    File('$pkgDir/pubspec.yaml').writeAsStringSync(
      'name: $name\nenvironment:\n  sdk: ^3.11.0\n',
    );
    final cfg = {
      'configVersion': 2,
      'packages': [
        {
          'name': name,
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.11',
        },
        {
          'name': 'openstrap_edge',
          'rootUri': Uri.directory(repo).toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.11',
        },
        if (name != 'openstrap_analytics')
          {
            'name': 'openstrap_analytics',
            'rootUri': Uri.directory('$worldRoot/_packages/openstrap_analytics')
                .toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
        if (name != 'fixture_dispatch')
          {
            'name': 'fixture_dispatch',
            'rootUri':
                Uri.directory('$worldRoot/_packages/fixture_dispatch').toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
      ],
    };
    Directory('$pkgDir/.dart_tool').createSync(recursive: true);
    File('$pkgDir/.dart_tool/package_config.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(cfg));
  }
}
