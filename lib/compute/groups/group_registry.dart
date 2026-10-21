// group_registry.dart — validation and graph queries over a [GroupRegistry]
// (design 06 phase 1a). Pure; nothing at runtime calls it yet.

import 'group_types.dart';

const int _kMaxMembers = 3;

/// Every rule the registry must hold, as human-readable problems. Empty means
/// valid: unique ids, resolving deps, acyclic, at most 3 members, counter >= 1.
List<String> validateRegistry(GroupRegistry registry) {
  final problems = <String>[];
  final byId = <String, GroupDecl>{};
  for (final g in registry.groups) {
    if (byId.containsKey(g.id)) {
      problems.add('${g.id}: duplicate group id');
    }
    byId[g.id] = g;
    if (g.members.length > _kMaxMembers) {
      problems.add(
        '${g.id}: ${g.members.length} members (at most $_kMaxMembers)',
      );
    }
    if (g.counter < 1) {
      problems.add('${g.id}: counter ${g.counter} is below 1');
    }
  }
  for (final g in registry.groups) {
    for (final d in g.deps) {
      if (!byId.containsKey(d)) {
        problems.add('${g.id}: dependency "$d" is not a declared group');
      }
    }
  }
  // Cycle search (DFS, 3-colour). Each cycle is reported once, on the group
  // where it was first closed.
  final state = <String, int>{}; // 1 = on stack, 2 = done
  void visit(String id, List<String> path) {
    state[id] = 1;
    path.add(id);
    for (final d in byId[id]!.deps) {
      if (!byId.containsKey(d)) continue;
      if (state[d] == 1) {
        final cycle = [...path.sublist(path.indexOf(d)), d];
        problems.add('${cycle.first}: dependency cycle ${cycle.join(' -> ')}');
      } else if (state[d] == null) {
        visit(d, path);
      }
    }
    path.removeLast();
    state[id] = 2;
  }

  for (final id in byId.keys) {
    if (state[id] == null) visit(id, <String>[]);
  }
  return problems;
}

/// Every group id [id] depends on, directly or through other groups
/// (foundations included). Excludes [id] itself. Insertion-ordered
/// (breadth-first over declared dep order), so the result is deterministic.
Set<String> transitiveDeps(GroupRegistry registry, String id) {
  final byId = {for (final g in registry.groups) g.id: g};
  final out = <String>{};
  final queue = <String>[...?byId[id]?.deps];
  while (queue.isNotEmpty) {
    final d = queue.removeAt(0);
    if (d == id || !out.add(d)) continue;
    queue.addAll(byId[d]?.deps ?? const <String>[]);
  }
  return out;
}

/// The owner's cost rule per group (`group id -> member costs`): at least one
/// member, and max < 2 x min (strict), and at most 3 members. Empty means
/// every group is valid.
List<String> costRuleProblems(Map<String, List<double>> groupMemberCosts) {
  final problems = <String>[];
  for (final e in groupMemberCosts.entries) {
    final c = e.value;
    if (c.isEmpty) {
      problems.add('${e.key}: no members');
      continue;
    }
    if (c.length > _kMaxMembers) {
      problems.add('${e.key}: ${c.length} members (at most $_kMaxMembers)');
    }
    var lo = c.first, hi = c.first;
    for (final v in c) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (!(hi < 2 * lo)) {
      problems.add('${e.key}: max cost $hi is not < 2 x min cost $lo');
    }
  }
  return problems;
}
