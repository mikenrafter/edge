// ratchets.dart — the registry of every "improvement list" (owner rule B).
//
// An improvement list is a baseline, allow-list or exception map that records
// existing debt in a guard. Each may only SHRINK. This file names them all and
// says how to count each. ratchet_lists_test.dart compares the counts at HEAD
// with the same lists at the target branch (env RATCHET_BASE) or, when that is
// unset, with the checked-in snapshot test/guards/ratchet_counts.json, and fails
// if any count grew. A list added to the registry is fine. A list removed from
// it fails (you cannot escape a ratchet by unregistering it).
//
// RED PHASE: the registry below is real data (it records what the tests found);
// every function is a stub that throws until the green phase implements it.
//
// Counts are `Map<String, int>` per list; the key names are part of the
// contract (see each [RatchetKind]).

/// How a list is stored, and so how it is counted.
enum RatchetKind {
  /// test/guards/heavy_calc_baseline.json
  /// (`{version, ruleVersions, occurrences: [{..., count}]}`).
  /// Counts: `entries` = occurrences.length, `occurrences` = sum of `count`.
  heavyBaselineJson,

  /// A flat JSON object `{ "<path>": <int size> }`
  /// (test/guards/file_size_exceptions.json).
  /// Counts: `entries` = key count, and one `size:<path>` per key holding that
  /// path's recorded size (a size may only go down; a key new in HEAD is
  /// growth).
  sizeMapJson,

  /// A Dart collection literal assigned to [RatchetList.symbol]
  /// (`symbol = <T>{...}` / `[...]`, optional `const`/type before the symbol,
  /// optional `<...>` type arguments right after `=`). Counts: `entries` = the
  /// number of top-level elements (map entries count once). Strings (single,
  /// double, triple, raw, adjacent-concatenated), comments, nested brackets and
  /// record values `(a: 1, b: 'x, y')` must not confuse the element count. When
  /// [RatchetList.sumField] is set, also `sum` = the sum of that named integer
  /// field over the elements' record values (`(count: 3, why: '...')`).
  dartLiteral,

  /// A Dart map whose values are themselves collection literals.
  /// Counts: `entries` = top-level entries, `leaves` = the total number of
  /// top-level elements across those value literals.
  dartLiteralNested,

  /// A `RegExp(...)` assigned to [RatchetList.symbol] whose pattern is built
  /// from adjacent string literals. Counts: `entries` = the number of TOP-LEVEL
  /// alternatives (split on `|` outside groups, character classes and escapes).
  dartRegexAlternatives,
}

class RatchetList {
  /// Stable name; the key in ratchet_counts.json. Never reused.
  final String id;

  /// Repo-relative path using forward slashes.
  final String file;
  final RatchetKind kind;

  /// The Dart identifier for the Dart kinds; null for the JSON kinds.
  final String? symbol;

  /// For [RatchetKind.dartLiteral]: a record field to sum into `sum`.
  final String? sumField;

  const RatchetList(
    this.id,
    this.file,
    this.kind, {
    this.symbol,
    this.sumField,
  });
}

/// Every improvement list found under lib/ and test/. Counts at the time of
/// writing are in the comment on each row.
const List<RatchetList> kRatchets = <RatchetList>[
  // 1986 entries, 2190 occurrences.
  RatchetList('heavy_calc_baseline', 'test/guards/heavy_calc_baseline.json',
      RatchetKind.heavyBaselineJson),
  // Created by the green phase: one entry per file over 6,000 code lines.
  RatchetList('file_size_exceptions', 'test/guards/file_size_exceptions.json',
      RatchetKind.sizeMapJson),
  // 33
  RatchetList('worker_unresolved_ok', 'lib/util/worker_entries.dart',
      RatchetKind.dartLiteral,
      symbol: 'kUnresolvedOk'),
  // 50
  RatchetList('p21_pinned_dynamic_writers',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_pinnedDynamicWriters'),
  // 13
  RatchetList('p21_pinned_table_lists',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_pinnedTableLists'),
  // 2 tables, 12 writer members (`LocalDb.putDayResult` -> verbs).
  RatchetList('p21_allowed_writers',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteralNested,
      symbol: '_allowed'),
  // 6
  RatchetList('p22_legacy_callers', 'test/step2/p22_decode_guard_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_legacyCallers'),
  // 6
  RatchetList('p23_direct_callers', 'test/step2/p23_call_sites_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_directCallers'),
  // 2 files, `count` sums to 9.
  RatchetList('p24_from_json_callers', 'test/step2/p24_call_sites_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_fromJsonCallers', sumField: 'count'),
  // 10
  RatchetList('ecg_gesture_consumer_allow',
      'test/ecg_gesture_consumer_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allow'),
  // 1
  RatchetList('observation_isolation_allowed',
      'test/observation_isolation_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowedToNameTheTable'),
  // 2 alternatives.
  RatchetList('sample_guard_slice_entry',
      'test/sample_archive/sample_guard_test.dart',
      RatchetKind.dartRegexAlternatives,
      symbol: '_sliceEntry'),
  // 3
  RatchetList('scan_lock_entry_points_allowlist',
      'test/scan_lock_entry_points_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowlist'),
  // 1
  RatchetList('one_band_event_switch_allowlist',
      'test/one_band_event_switch_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowlist'),
  // 6
  RatchetList('ui2_spinner_status_allowed',
      'test/ui2_spinner_status_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowed'),
  // 1
  RatchetList('copy_jargon_allowed_keys', 'test/copy_jargon_guard_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_allowedKeys'),
  // 3
  RatchetList('copy_jargon_allowed_prefixes',
      'test/copy_jargon_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowedPrefixes'),
  // 1
  RatchetList('background_legacy_inline_dispatches',
      'test/guards/support/legacy_inline_dispatches.dart',
      RatchetKind.dartLiteral,
      symbol: 'kLegacyInlineDispatches'),
  // 0 (empty today: a new exemption is growth).
  RatchetList('heavy_migration_methods',
      'test/guards/support/heavy_guard.dart', RatchetKind.dartLiteral,
      symbol: 'kMigrationMethods'),
];

/// Reads a repo-relative file; null when it does not exist.
typedef SourceReader = Future<String?> Function(String repoRelativePath);

/// Reads from a directory (a work tree or a fixture).
SourceReader dirReader(String root) =>
    throw UnimplementedError('dirReader');

/// Reads `git show <ref>:<path>` in [repoDir]. Null when the file does not
/// exist at the ref. An unresolvable ref throws a [StateError] naming the ref
/// (never silently skips; same behaviour as readBaselineAtRef).
SourceReader gitRefReader(String ref, {required String repoDir}) =>
    throw UnimplementedError('gitRefReader');

/// Counts one list from its file's text. See [RatchetKind] for the keys.
/// Throws [FormatException]/[StateError] naming the list when the text does not
/// contain what the kind expects (missing symbol, bad JSON).
Map<String, int> countRatchet(RatchetList list, String source) =>
    throw UnimplementedError('countRatchet');

/// Counts every list in [lists] through [read]. A list whose file is missing is
/// omitted when [missingIsError] is false (it was introduced after that
/// snapshot) and throws a [StateError] naming the list when true (HEAD must
/// have every registered file).
Future<Map<String, Map<String, int>>> countRatchets(
  SourceReader read, {
  Iterable<RatchetList> lists = kRatchets,
  bool missingIsError = true,
}) =>
    throw UnimplementedError('countRatchets');

/// One reason per count that is higher in [head] than in [base]. A list that is
/// only in [head] (newly registered) is fine. A count key absent from [base]
/// reads as 0 there, so a new key with a positive value is growth. A key that
/// disappeared from [head], or a lower count, is a shrink and passes. Each
/// reason names the list id and the key.
List<String> ratchetGrowth({
  required Map<String, Map<String, int>> base,
  required Map<String, Map<String, int>> head,
}) =>
    throw UnimplementedError('ratchetGrowth');

/// One reason per id in [baseIds] that is not in [headIds] (unregistered).
/// Extra ids in [headIds] are fine.
List<String> unregisteredRatchets({
  required Iterable<String> baseIds,
  required Iterable<String> headIds,
}) =>
    throw UnimplementedError('unregisteredRatchets');

/// test/guards/ratchet_counts.json: `{"version": 1, "lists": {id: {key: int}}}`.
Map<String, Map<String, int>> parseRatchetSnapshot(String json) =>
    throw UnimplementedError('parseRatchetSnapshot');

String encodeRatchetSnapshot(Map<String, Map<String, int>> counts) =>
    throw UnimplementedError('encodeRatchetSnapshot');
