import 'dart:io';

/// The files that make up the `LocalDb` library: `lib/data/db.dart` plus every
/// file it names in a `part` directive, as repo-relative paths.
///
/// Source-reading tests use this instead of naming `db.dart` alone, so moving
/// code between the root and its parts does not change what they check. Only
/// real parts count: another library placed under `lib/data/db/` is not here.
List<String> dbLibraryFiles() {
  final root = File('lib/data/db.dart').readAsStringSync();
  final parts = [
    for (final m in RegExp(r"^part '([^']+)';", multiLine: true).allMatches(root))
      'lib/data/${m.group(1)}',
  ];
  return ['lib/data/db.dart', ...parts];
}

/// `db.dart` and its parts, concatenated: the library's source as one string.
String dbLibrarySource() =>
    dbLibraryFiles().map((path) => File(path).readAsStringSync()).join('\n');
