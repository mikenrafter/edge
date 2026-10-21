// edge_groups.dart — edge's registry entries and the key-ownership maps
// (design 06 phase 1a). Nothing at runtime reads this yet.
//
// RED STATE: the ownership maps are empty on purpose; green fills them from
// the real key sets (see test/groups/group_key_ownership_test.dart).

import 'group_types.dart';

/// Edge-side groups: the steps edge owns around analytics results.
const List<GroupDecl> kEdgeGroups = <GroupDecl>[
  GroupDecl(
    id: 'edge.assembly',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['deriveDayBundle'],
    files: ['lib/compute/onehz_pipeline.dart'],
  ),
  GroupDecl(
    id: 'edge.series_shaping',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['seriesMethodFor'],
    files: ['lib/compute/engine/day_compute.dart'],
  ),
  GroupDecl(
    id: 'edge.gates_overrides',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['blankNightInBundle'],
    files: ['lib/compute/sleep_blank.dart'],
  ),
];

/// PLACEHOLDER (until 1b): stand-ins for the groups analytics will declare,
/// from the proposal in design 06 phase-1 plan section 4. Replaced by
/// `kAnalyticsGroupRegistry` in 1b; the ids may change then.
const List<GroupDecl> kAnalyticsPlaceholderGroups = <GroupDecl>[];

/// Members whose per-day cost is not yet measured (the heavy cost test fills
/// them in). A ratchet list: it may only shrink.
const List<String> kGroupUnknownCostMembers = <String>[
  // The three edge entries; analytics members join in 1b.
  'deriveDayBundle',
  'seriesMethodFor',
  'blankNightInBundle',
];

/// Top-level day-bundle key -> owning group id. Empty in red.
const Map<String, String> kBundleKeyOwner = <String, String>{};

/// `metric_series` key -> owning group id. Empty in red.
const Map<String, String> kSeriesKeyOwner = <String, String>{};

/// Keys a derive produces only under a condition the test fixtures may not
/// meet (documented per key so the "no phantom key" check stays honest).
/// Empty in red; green lists each with its condition.
const Map<String, String> kConditionalKeys = <String, String>{};
