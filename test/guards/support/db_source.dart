// db_source.dart — the text of `LocalDb` as it read before the step 0b split.
//
// `lib/data/db.dart` keeps every LocalDb static as a declaration and forwards
// the large ones (`=> _ldbFoo(args);`) to a top-level function in a part file
// under `lib/data/db/`. Source-scanning tests look for a member's text (its
// SQL, its call order). They read it through [readDbSource], which puts each
// moved body back behind its signature, so a scan sees what it saw before the
// split and cannot be blinded by moving code into a part.

import 'dart:io';

final RegExp _forward = RegExp(r'\s=> (_ldb\w+)(?:<[^>]*>)?\([^;]*\);');
final RegExp _partDirective = RegExp(r"^part 'db/(\w+\.dart)';", multiLine: true);

/// `lib/data/db/*.dart` files named by `lib/data/db.dart` (relative paths).
List<String> dbPartPaths([String root = '.']) {
  final src = File('$root/lib/data/db.dart').readAsStringSync();
  return [
    for (final m in _partDirective.allMatches(src)) 'lib/data/db/${m[1]}',
  ];
}

/// Moved bodies by function name: the text after the parameter list.
Map<String, String> _movedBodies(String root) {
  final out = <String, String>{};
  for (final path in dbPartPaths(root)) {
    final lines = File('$root/$path').readAsLinesSync();
    final chunks = <StringBuffer>[];
    for (final l in lines) {
      final starts =
          l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('//') && !l.startsWith('part of');
      if (starts) chunks.add(StringBuffer());
      if (chunks.isNotEmpty) chunks.last.writeln(l);
    }
    for (final c in chunks) {
      final t = c.toString();
      final name = RegExp(r'\b(_ldb\w+)').firstMatch(t)!;
      var i = t.indexOf('(', name.end);
      var depth = 0;
      for (; i < t.length; i++) {
        if (t[i] == '(') depth++;
        if (t[i] == ')' && --depth == 0) break;
      }
      out[name[1]!] = t.substring(i + 1).trim();
    }
  }
  return out;
}

/// db.dart with every forwarded body put back. [root] is the package root.
String readDbSource([String root = '.']) {
  final bodies = _movedBodies(root);
  final src = File('$root/lib/data/db.dart').readAsStringSync();
  return src.replaceAllMapped(_forward, (m) {
    final body = bodies[m[1]!];
    if (body == null) throw StateError('no moved body for ${m[1]}');
    return ' $body';
  });
}

/// A LocalDb part file reports as `lib/data/db.dart`, the file it belongs to.
String canonDbPath(String path) =>
    path.startsWith('lib/data/db/') ? 'lib/data/db.dart' : path;
