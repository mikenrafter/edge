// Design 06 phase 1b: edge consumes the registry analytics declares.
//
// RED until edge drops its 1a placeholders and merges
// `kAnalyticsGroupRegistry` with `kEdgeGroups`. The checks:
//  - the merged registry validates (and every bundle/series key owner names a
//    declared group);
//  - every analytics function edge's compute layer calls is a member or api
//    entry of exactly one group, or sits in [kUnregisteredAnalyticsCalls] (trivial
//    utilities, each with a reason; a shrink-only ratchet);
//  - edge entries depend only on declared ids;
//  - edge no longer declares analytics placeholder groups.
//
// CALL-SITE INVENTORY. Edge files under lib/compute/** that import
// package:openstrap_analytics are scanned. With `as ana`, `ana.name(` is a
// call; with an unprefixed import, `name(` is a call when `name` is a
// top-level function in the analytics package and edge's own file does not
// declare it. Analytics' function names come from its lib/src sources
// (located through .dart_tool/package_config.json), so the pinned package is
// what is checked.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana show kAnalyticsGroupRegistry;
import 'package:openstrap_edge/compute/groups/edge_groups.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/group_types.dart';

/// Analytics functions edge calls that are deliberately in no group: trivial,
/// stateless utilities whose change cannot alter a stored result on its own.
/// name -> reason. A ratchet (test/guards/support/ratchets.dart): it may only
/// shrink.
const Map<String, String> kUnregisteredAnalyticsCalls = <String, String>{};

/// The merged registry. The analytics decls are re-built field by field so
/// this works both while edge has its own copy of the types (1a) and once it
/// re-exports analytics' (green).
GroupRegistry _merged() {
  final a = ana.kAnalyticsGroupRegistry;
  final fromAnalytics = <GroupDecl>[
    for (final dynamic d in a.groups)
      GroupDecl(
        id: d.id as String,
        kind: GroupKind.values.byName((d.kind as Enum).name),
        counter: d.counter as int,
        members: List<String>.from(d.members as List),
        api: List<String>.from(d.api as List),
        deps: List<String>.from(d.deps as List),
        inputs: [
          for (final dynamic i in d.inputs as List)
            InputDecl(i.id as String,
                InputScope.values.byName((i.scope as Enum).name)),
        ],
        files: List<String>.from(d.files as List),
      ),
  ];
  return GroupRegistry(1, [...fromAnalytics, ...kEdgeGroups]);
}

String _analyticsRoot() {
  final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
      as Map<String, dynamic>;
  final pkg = (cfg['packages'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((p) => p['name'] == 'openstrap_analytics');
  var root = Uri.parse(pkg['rootUri'] as String);
  if (!root.isAbsolute) {
    root = Directory('.dart_tool').absolute.uri.resolveUri(root);
  }
  return root.toFilePath();
}

final RegExp _fnDecl = RegExp(
    r'^(?!(?:import|export|part|library|class|enum|typedef|const|final|var|late|abstract|mixin|extension|static|return|if|for|while|switch|else|sealed|base|interface)\b)[A-Za-z_][\w<>,?\[\]. ]*?\s(\w+)\s*(?:<[^>(]*>)?\(',
    multiLine: true);

String _strip(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

Set<String> _analyticsFunctions() {
  final out = <String>{};
  for (final f in Directory('${_analyticsRoot()}/lib/src')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    for (final m in _fnDecl.allMatches(_strip(f.readAsStringSync()))) {
      final n = m.group(1)!;
      if (!n.startsWith('_')) out.add(n);
    }
  }
  return out;
}

/// function name -> edge files (repo-relative) calling it.
Map<String, Set<String>> _callInventory() {
  final fns = _analyticsFunctions();
  final calls = <String, Set<String>>{};
  final importRe = RegExp(
      r'''import\s+'package:openstrap_analytics/onehz\.dart'\s*(as\s+(\w+))?([^;]*);''');
  for (final f in Directory('lib/compute')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    final src = _strip(f.readAsStringSync());
    final im = importRe.firstMatch(src);
    if (im == null) continue;
    final prefix = im.group(2);
    final own = {for (final m in _fnDecl.allMatches(src)) m.group(1)!};
    final path = f.path.replaceAll('\\', '/');
    if (prefix != null) {
      for (final m in RegExp('\\b$prefix\\.(\\w+)\\s*(?:<[^>(]*>)?\\(').allMatches(src)) {
        if (fns.contains(m.group(1))) {
          (calls[m.group(1)!] ??= <String>{}).add(path);
        }
      }
    } else {
      final show = RegExp(r'show\s+([\w\s,]+)').firstMatch(im.group(3)!)?.group(1);
      final only = show?.split(',').map((e) => e.trim()).toSet();
      for (final m in RegExp(r'(?<![\w.])(\w+)\s*(?:<[^>(]*>)?\(').allMatches(src)) {
        final n = m.group(1)!;
        if (!fns.contains(n) || own.contains(n)) continue;
        if (only != null && !only.contains(n)) continue;
        (calls[n] ??= <String>{}).add(path);
      }
    }
  }
  return calls;
}

void main() {
  test('the merged analytics + edge registry validates', () {
    final r = _merged();
    expect(validateRegistry(r), isEmpty);
    expect(r.groups.map((g) => g.id).toSet(), containsAll(<String>[
      'sleep.stage', 'hrv.freq', 'night.rhythm', 'day.blocks',
      'readiness.stress_illness', 'activity.load', 'body.spo2_temp_coverage',
      'found.rr_correction',
    ]));
  });

  test('every bundle and series key owner is a declared group', () {
    final ids = _merged().groups.map((g) => g.id).toSet();
    final dangling = <String>[
      for (final e in {...kBundleKeyOwner, ...kSeriesKeyOwner}.entries)
        if (!ids.contains(e.value)) '${e.key} -> ${e.value}',
    ];
    expect(dangling, isEmpty);
  });

  test('every analytics function edge/compute calls is a member or api entry of exactly one group', () {
    final calls = _callInventory();
    // Inventory sanity: a scanner regression must not read as "all covered".
    expect(calls.length, greaterThan(40), reason: 'call-site scan found too little');
    final owners = <String, List<String>>{};
    for (final g in _merged().groups) {
      for (final m in [...g.members, ...g.api]) {
        (owners[m] ??= <String>[]).add(g.id);
      }
    }
    final problems = <String>[];
    for (final fn in calls.keys.toList()..sort()) {
      final o = owners[fn] ?? const <String>[];
      if (kUnregisteredAnalyticsCalls.containsKey(fn)) {
        if (o.isNotEmpty) problems.add('$fn: allow-listed but also in ${o.join(', ')}');
      } else if (o.isEmpty) {
        problems.add('$fn: called from ${calls[fn]!.first} but in no group');
      } else if (o.length > 1) {
        problems.add('$fn: in ${o.length} groups (${o.join(', ')})');
      }
    }
    expect(problems, isEmpty,
        reason: '${problems.length} problems, first: ${problems.take(15).join('; ')}');
  });

  test('allow-listed utilities carry a reason and are really called', () {
    final calls = _callInventory();
    for (final e in kUnregisteredAnalyticsCalls.entries) {
      expect(e.value.trim(), isNotEmpty, reason: e.key);
      expect(calls.containsKey(e.key), isTrue, reason: '${e.key} is not called');
    }
  });

  test('edge entries depend only on declared ids', () {
    final ids = _merged().groups.map((g) => g.id).toSet();
    for (final g in kEdgeGroups) {
      for (final d in g.deps) {
        expect(ids, contains(d), reason: '${g.id} -> $d');
      }
    }
  });

  test('edge no longer declares analytics placeholder groups', () {
    final src = File('lib/compute/groups/edge_groups.dart').readAsStringSync();
    expect(src, isNot(contains('kAnalyticsPlaceholderGroups')),
        reason: 'placeholders move to analytics (kAnalyticsGroupRegistry)');
  });
}
