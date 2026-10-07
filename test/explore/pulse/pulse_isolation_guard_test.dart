// Source guard: the pulse-pattern research prototype stays outside the coach
// and the health export (AGENTS.md section 3.13; the coach reads only
// allow-listed v_* views, health export ships numbers off the device).
//
//  * nothing under lib/explore/pulse/ imports lib/coach/ or lib/health/;
//  * nothing under lib/coach/ or lib/health/ imports lib/explore/pulse/.
//
// These pass before the prototype is implemented; they stop the prototype
// from being wired into either path later. Direct imports/exports/parts are
// checked, which is where such a wiring would start.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _directive = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true);

/// The lib-relative target of every import/export/part in [source], resolved
/// from the lib-relative [fromPath] (e.g. `explore/pulse/a.dart`). Targets
/// outside lib/ and `dart:` URIs come back as-is.
List<String> importTargets(String source, String fromPath) {
  final out = <String>[];
  for (final m in _directive.allMatches(source)) {
    final uri = m.group(1)!;
    if (uri.startsWith('package:openstrap_edge/')) {
      out.add(uri.substring('package:openstrap_edge/'.length));
    } else if (uri.contains(':')) {
      out.add(uri);
    } else {
      out.add(Uri.parse('/$fromPath').resolve(uri).path.substring(1));
    }
  }
  return out;
}

List<File> _dartFiles(String dir) {
  final d = Directory(dir);
  expect(d.existsSync(), isTrue, reason: '$dir must exist (vacuous otherwise)');
  final files = d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  expect(files, isNotEmpty, reason: '$dir has no sources (vacuous otherwise)');
  return files;
}

String _libRel(File f) =>
    f.path.replaceAll('\\', '/').split('lib/').skip(1).join('lib/');

List<String> _offenders(String dir, bool Function(String target) bad) {
  final hits = <String>[];
  for (final f in _dartFiles(dir)) {
    final from = _libRel(f);
    for (final t in importTargets(f.readAsStringSync(), from)) {
      if (bad(t)) hits.add('$from -> $t');
    }
  }
  return hits;
}

void main() {
  group('the scanner itself', () {
    test('resolves relative, package and parent-directory imports', () {
      const src = '''
import 'package:flutter/widgets.dart';
import 'package:openstrap_edge/coach/coach_views.dart';
import '../../health/export.dart';
import '../coach/x.dart' show Y;
export "pulse_pattern_night.dart";
part 'p.dart';
// import 'package:openstrap_edge/coach/commented_out.dart';
''';
      expect(importTargets(src, 'explore/pulse/a.dart'), [
        'package:flutter/widgets.dart',
        'coach/coach_views.dart',
        'health/export.dart',
        'explore/coach/x.dart',
        'explore/pulse/pulse_pattern_night.dart',
        'explore/pulse/p.dart',
      ]);
    });
  });

  test('lib/explore/pulse imports nothing from coach or health', () {
    expect(
        _offenders('lib/explore/pulse',
            (t) => t.startsWith('coach/') || t.startsWith('health/')),
        isEmpty);
  });

  test('lib/coach does not import the pulse prototype', () {
    expect(
        _offenders('lib/coach', (t) => t.startsWith('explore/pulse/')),
        isEmpty);
  });

  test('lib/health does not import the pulse prototype', () {
    expect(
        _offenders('lib/health', (t) => t.startsWith('explore/pulse/')),
        isEmpty);
  });
}
