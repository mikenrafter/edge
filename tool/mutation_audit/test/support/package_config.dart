import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes `.dart_tool/package_config.json` the way `pub get` does: [packages]
/// maps a package name to `(rootUri relative to .dart_tool, packageUri)`.
/// `writeConfig(root, {'demo': ('../', 'lib/')})` is the audited package.
void writeConfig(String root, Map<String, (String, String)> packages) {
  File(p.join(root, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final e in packages.entries) {'name': e.key, 'rootUri': e.value.$1, 'packageUri': e.value.$2},
      ],
    }));
}

/// The usual config of the audited package `demo` at the root of the export.
void writeDemoConfig(String root) => writeConfig(root, {'demo': ('../', 'lib/')});
