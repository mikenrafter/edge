// group_registry.dart — validation and graph queries over a [GroupRegistry]
// (design 06 phase 1a). Pure; nothing at runtime calls it yet.

import 'group_types.dart';

/// Every rule the registry must hold, as human-readable problems. Empty means
/// valid: unique ids, resolving deps, acyclic, at most 3 members, counter >= 1.
List<String> validateRegistry(GroupRegistry registry) =>
    throw UnimplementedError('validateRegistry');

/// Every group id [id] depends on, directly or through other groups
/// (foundations included). Excludes [id] itself.
Set<String> transitiveDeps(GroupRegistry registry, String id) =>
    throw UnimplementedError('transitiveDeps');

/// The owner's cost rule per group (`group id -> member costs`): at least one
/// member, and max < 2 x min (strict), and at most 3 members. Empty means
/// every group is valid.
List<String> costRuleProblems(Map<String, List<double>> groupMemberCosts) =>
    throw UnimplementedError('costRuleProblems');
