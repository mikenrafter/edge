import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The packages of `<exportPath>/.dart_tool/package_config.json` as (name,
/// root directory). Empty when there is no package config yet or it is damaged.
List<({String name, String path})> packageConfigEntries(String exportPath) {
  final file = File(p.join(exportPath, '.dart_tool', 'package_config.json'));
  if (!file.existsSync()) return const [];
  final Object? doc;
  try {
    doc = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return const [];
  }
  final packages = doc is Map ? doc['packages'] : null;
  if (packages is! List) return const [];
  final base = Uri.directory(p.join(exportPath, '.dart_tool'));
  final out = <({String name, String path})>[];
  for (final pkg in packages) {
    final root = pkg is Map ? pkg['rootUri'] : null;
    final name = pkg is Map ? pkg['name'] : null;
    if (root is! String || name is! String) continue;
    final Uri uri;
    try {
      uri = base.resolve(root);
    } on FormatException {
      continue;
    }
    if (uri.scheme != 'file') continue;
    out.add((name: name, path: p.normalize(uri.toFilePath())));
  }
  return out;
}

/// The packages of the export's package config that have a build hook
/// (`hook/build.dart`: native assets), sorted. Such a hook may download or
/// compile a library the first time the tests run (`sqlite3` downloads a
/// prebuilt one), which needs the network.
List<String> packagesWithBuildHooks(String exportPath) => [
      for (final e in packageConfigEntries(exportPath))
        if (File(p.join(e.path, 'hook', 'build.dart')).existsSync()) e.name,
    ]..sort();
