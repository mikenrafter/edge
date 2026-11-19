// The checked compatibility profile: every fork table and column, what the
// export does with it, and what the tagged official receiver does on merge.
// Data lives in `profile_tables.dart`/`profile_target.dart` (frozen from the
// captured schemas); this file owns the types and the validation.
//
// Table policy codes follow the spec §4.1 and are exhaustive dispositions, not
// silent filters: K kept, M mapped, R recomputed (empty in the target, which
// rebuilds it), D dropped from the official file (stays in the fork and the
// optional recovery file).
import 'schema_catalog.dart';

/// The immutable release this profile was frozen against.
const officialTargetTag = 'v0.12.2';
const officialTargetSha = 'cd64eaa89948409ccffbea19ee48d7bd22dcb808';
const officialTargetSchema = 62;
const officialTargetAlgorithm = 124;

enum TablePolicy {
  kept('K'),
  mapped('M'),
  recomputed('R'),
  dropped('D');

  const TablePolicy(this.code);
  final String code;

  /// Rows travel to the official file.
  bool get carriesRows => this == kept || this == mapped;
}

/// What happens to one source column.
enum ColumnDisposition {
  /// Copied as stored into the same-named target column.
  keep,

  /// Fork-computed or unrepresentable value: the target column gets NULL or
  /// its default; the clearing is reported only when the source was not NULL.
  clear,

  /// The target has no such column; the value is inventoried in the manifest.
  omit,

  /// Copied after a reviewed key/reference rewrite (never numeric conversion).
  rewrite,

  /// Kept only where its provenance column names a measured input source;
  /// otherwise cleared. Unknown provenance stays unknown, never guessed.
  byProvenance,

  /// The whole table is R or D: no column travels.
  tableDropped,
}

/// How the tagged importer resolves a row whose key already exists locally.
enum MergeRule {
  /// Existing target slot wins; the file only fills missing ones.
  fillMissing,

  /// Strictly newer `updated_at` wins; equal or local wins.
  newerUpdatedAtWins,

  /// Strictly newer `created_at` wins; equal or local wins.
  newerCreatedAtWins,

  /// The whole date's set merges by the maximum `updated_at`.
  wholeDateSetByUpdatedAt,

  /// The local row wins whenever it exists.
  localWins,

  /// An existing target row wins and the file's row is ignored.
  existingTargetWins,

  /// INSERT OR REPLACE: the file's row replaces the local one.
  plainReplace,

  /// Race protection: discarded/finalized local races win, newer incoming
  /// races replace.
  raceProtected,

  /// Decided local answer wins; pending resolves by age.
  decidedLocalWins,

  /// A newer or equal overlapping local correction wins.
  overlappingLocalWins,

  /// Singleton row with receiver-owned revision merge.
  singleton,

  /// Surrogate id is dropped; rows dedupe by their content window.
  contentDeduped,

  /// Parent verdict decides: children follow their session.
  followsParent,

  /// A higher incoming value replaces a lower local one (the prune cursor).
  higherValueWins,

  /// Adopted only by a recipient with no policy/archive/readings of its own;
  /// otherwise the populated target keeps what it has.
  adoptedByEmptyTargetOnly,
}

class MergeKey {
  const MergeKey(this.columns, this.rule, [this.note = '']);

  /// The domain key the receiver merges on (not necessarily the SQL PK).
  final List<String> columns;
  final MergeRule rule;
  final String note;
}

/// One fork table's policy.
class TableProfile {
  const TableProfile({
    required this.policy,
    required this.meaning,
    required this.evidence,
    this.dest,
    this.keep = const [],
    this.clear = const [],
    this.omit = const [],
    this.rewrite = const [],
    this.merge,
    this.optional = false,
    this.optionalOmissions = const [],
    this.createsEmptyDest = false,
    this.dropped = const [],
    this.provenance = const [],
    this.targetOnly = const [],
    this.emptyConstants = const {},
    this.transforms = const [],
    this.rowRule,
  });

  final TablePolicy policy;

  /// What the table means for the transfer, in plain words.
  final String meaning;

  /// `lib/`-relative source evidence for the table's creator.
  final String evidence;

  /// The target table rows travel into (K/M); null when none.
  final String? dest;

  final List<String> keep, clear, omit, rewrite, provenance;

  /// Target columns the source has no value for: the target default applies.
  final List<String> targetOnly;

  /// A cleared column the target declares NOT NULL without a default gets this
  /// SQL literal instead of NULL (a valid empty value, never a made-up one).
  final Map<String, String> emptyConstants;

  /// Named whole-table transformations (archive expansion, re-encoding).
  final List<String> transforms;

  /// Which rows travel, when not all of them; null means every row.
  final String? rowRule;

  /// R/D tables list every source column here so a new column is still caught.
  final List<String> dropped;
  final MergeKey? merge;

  /// Created lazily or only on legacy paths: absent from some real databases.
  final bool optional;

  /// Known retired fork columns: classified when present, absent on fresh
  /// installs. Only omitted columns may be optional; portable bytes stay required.
  final List<String> optionalOmissions;
  Set<String> get requiredColumns => columns.keys.toSet().difference(optionalOmissions.toSet());

  /// R tables whose target layout needs the table to exist (empty).
  final bool createsEmptyDest;

  Map<String, ColumnDisposition> get columns => {
    for (final c in keep) c: ColumnDisposition.keep,
    for (final c in clear) c: ColumnDisposition.clear,
    for (final c in omit) c: ColumnDisposition.omit,
    for (final c in rewrite) c: ColumnDisposition.rewrite,
    for (final c in provenance) c: ColumnDisposition.byProvenance,
    for (final c in dropped) c: ColumnDisposition.tableDropped,
  };
}

/// A value-domain rule: which enum values the target's parser accepts for a
/// column, and what happens to a row carrying any other value.
class EnumPolicy {
  const EnumPolicy(
    this.table,
    this.column,
    this.targetValues,
    this.onOther,
    this.evidence,
  );
  final String table, column;
  final Set<String> targetValues;
  final EnumOther onOther;

  /// Where the target parses this column (`v0.12.2:` path and line).
  final String evidence;
}

enum EnumOther {
  /// The target would throw: the row (and its dependents) is omitted exactly.
  omitRow,

  /// The target falls back safely: the value is kept.
  keepValue,

  /// The column is cleared and reported.
  clearColumn,
}

/// A target-recognized export carrier written outside the row merge.
class CarrierTable {
  const CarrierTable(this.name, this.reader, this.meaning);
  final String name, reader, meaning;
}

/// One shape or classification problem. Equality is by text so tests can
/// compare complete gap lists.
sealed class CoverageGap {
  const CoverageGap(this.table);
  final String table;
  String get text;
  @override
  String toString() => text;
}

class UnclassifiedTable extends CoverageGap {
  const UnclassifiedTable(super.table);
  @override
  String get text => 'unclassified table $table';
}

class UnclassifiedColumn extends CoverageGap {
  const UnclassifiedColumn(super.table, this.column);
  final String column;
  @override
  String get text => 'unclassified column $table.$column';
}

class StaleColumn extends CoverageGap {
  const StaleColumn(super.table, this.column);
  final String column;
  @override
  String get text => 'profile column $table.$column is not in the schema';
}

class MissingRequiredTable extends CoverageGap {
  const MissingRequiredTable(super.table);
  @override
  String get text => 'profile table $table is absent and not optional';
}

class UnsupportedShape extends CoverageGap {
  const UnsupportedShape(super.table, this.why);
  final String why;
  @override
  String get text => 'unsupported shape $table: $why';
}

class OfficialProfile {
  const OfficialProfile({
    required this.tables,
    required this.carriers,
    required this.enums,
  });

  final Map<String, TableProfile> tables;
  final List<CarrierTable> carriers;
  final List<EnumPolicy> enums;

  /// Internal consistency of the frozen policy itself (no database needed).
  List<String> problems() {
    final out = <String>[];
    for (final e in tables.entries) {
      final t = e.value;
      final seen = <String>{};
      for (final c in [
        ...t.keep,
        ...t.clear,
        ...t.omit,
        ...t.rewrite,
        ...t.provenance,
        ...t.dropped,
      ]) {
        if (!seen.add(c)) out.add('${e.key}.$c is classified twice');
      }
      if (t.policy.carriesRows) {
        if (t.dest == null) out.add('${e.key}: ${t.policy.code} needs a dest');
        if (t.dropped.isNotEmpty) {
          out.add('${e.key}: ${t.policy.code} cannot list dropped columns');
        }
        if (t.keep.isEmpty && t.rewrite.isEmpty && t.provenance.isEmpty) {
          out.add('${e.key}: ${t.policy.code} keeps no column');
        }
        if (t.merge == null) out.add('${e.key}: no merge key');
        for (final k in t.merge?.columns ?? const <String>[]) {
          if (!t.keep.contains(k) &&
              !t.rewrite.contains(k) &&
              !t.provenance.contains(k)) {
            out.add('${e.key}: merge key $k is not carried');
          }
        }
      } else {
        if (t.keep.isNotEmpty ||
            t.clear.isNotEmpty ||
            t.omit.isNotEmpty ||
            t.provenance.isNotEmpty ||
            t.rewrite.isNotEmpty) {
          out.add('${e.key}: ${t.policy.code} must list columns as dropped');
        }
        if (t.merge != null) out.add('${e.key}: ${t.policy.code} has a merge');
        if (t.dest != null && !t.createsEmptyDest) {
          out.add('${e.key}: ${t.policy.code} dest needs createsEmptyDest');
        }
      }
      for (final c in t.optionalOmissions) {
        if (!t.omit.contains(c)) out.add('${e.key}.$c: optional column must be omitted');
      }
      for (final c in t.emptyConstants.keys) {
        if (!t.clear.contains(c)) out.add('${e.key}.$c: empty constant on a column that is not cleared');
      }
      if (t.policy == TablePolicy.mapped &&
          t.clear.isEmpty &&
          t.omit.isEmpty &&
          t.rewrite.isEmpty &&
          t.provenance.isEmpty &&
          t.transforms.isEmpty &&
          t.rowRule == null) {
        // An M table with no change at all is a K table in disguise.
        out.add('${e.key}: M changes nothing; classify it K');
      }
    }
    return out;
  }

  /// Compares an actual database's tables/columns with the profile.
  /// [source] is the fork snapshot's catalog. Every gap is returned.
  List<CoverageGap> coverage(SchemaCatalog source) {
    final gaps = <CoverageGap>[];
    for (final shape in source.tables.values) {
      final t = tables[shape.name];
      if (t == null) {
        gaps.add(UnclassifiedTable(shape.name));
        continue;
      }
      final profiled = t.columns;
      for (final c in shape.columnNames) {
        if (!profiled.containsKey(c)) {
          gaps.add(UnclassifiedColumn(shape.name, c));
        }
      }
      for (final c in t.requiredColumns) {
        if (!shape.columnNames.contains(c)) gaps.add(StaleColumn(shape.name, c));
      }
      if (t.policy.carriesRows) {
        if (shape.rowidAlias == null) {
          gaps.add(
            UnsupportedShape(
              shape.name,
              shape.withoutRowid
                  ? 'WITHOUT ROWID has no rowid to page by'
                  : shape.virtualTable
                  ? 'virtual table'
                  : 'every rowid alias is shadowed by a column',
            ),
          );
        }
        if (shape.nonPlainColumns.isNotEmpty) {
          gaps.add(
            UnsupportedShape(
              shape.name,
              'generated or hidden columns ${shape.nonPlainColumns}',
            ),
          );
        }
      }
    }
    for (final e in tables.entries) {
      if (!e.value.optional && !source.tables.containsKey(e.key)) {
        gaps.add(MissingRequiredTable(e.key));
      }
    }
    return gaps;
  }
}
