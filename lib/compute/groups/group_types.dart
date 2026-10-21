// group_types.dart — the calculation-group registry vocabulary (design 06).
//
// Pure Dart, const-constructible, no edge imports: in sub-step 1b these types
// move verbatim to openstrap_analytics (lib/src/onehz/registry/
// group_registry.dart) and this file becomes a one-line re-export. Keep it
// free of anything that would stop that move.

/// What a group is. Foundations carry no cost rule; edge transforms are the
/// gating/assembly steps edge runs around analytics results.
enum GroupKind { algorithm, foundation, edgeTransform }

/// How far in time a declared input reaches.
enum InputScope { day, dayAndNext, range, global }

class InputDecl {
  /// An id from edge's input catalogue.
  final String id;
  final InputScope scope;
  const InputDecl(this.id, this.scope);
}

class GroupDecl {
  /// Stable; never reused after a split or merge.
  final String id;
  final GroupKind kind;

  /// Plain integer, bumped when the group's algorithm changes (owner Q2).
  final int counter;

  /// Exported function names, at most 3.
  final List<String> members;

  /// Group ids this group reads, foundations included.
  final List<String> deps;
  final List<InputDecl> inputs;

  /// Repo-relative paths this group's output depends on.
  final List<String> files;

  const GroupDecl({
    required this.id,
    required this.kind,
    required this.counter,
    required this.members,
    this.deps = const [],
    this.inputs = const [],
    this.files = const [],
  });
}

class GroupRegistry {
  final int registryVersion;
  final List<GroupDecl> groups;
  const GroupRegistry(this.registryVersion, this.groups);
}
