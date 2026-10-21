// input_revision_store.dart — per-input revisions (design 06 phase 1c).
//
// `input_revision(source, scope, rev)`: one counter per catalogued input and
// scope (a local day label, or '' for a global input). Table inputs are bumped
// by AFTER INSERT/UPDATE/DELETE triggers generated from `kInputCatalogue`;
// setter inputs (profile, policy) bump through [bumpInputRev]; `decoded` is the
// existing `input_rev` 15-minute buckets, summed per day on read.
//
// Rules: a revision only ever goes up. `wipeAll` keeps this table (a later
// write must not reuse a number a stamp may already hold), and a restore never
// copies a foreign file's revisions (the merged rows bump ours via triggers).
//
// The bump is UPSERT-free (INSERT OR IGNORE, then UPDATE rev = rev + 1):
// Android 8-10 ship a SQLite without ON CONFLICT DO UPDATE (D32 hit the same).
// Nothing here backfills, so it is cheap under iOS's CPU watchdog (invariant
// 11); a missing row reads as revision 0.

import 'package:sqflite/sqflite.dart';

import '../../compute/groups/input_catalogue.dart';
import '../db.dart';

/// source -> scope -> revision. Absent means revision 0.
typedef InputRevSnapshot = Map<String, Map<String, int>>;

String _q(String s) => "'${s.replaceAll("'", "''")}'";

/// The two statements that bump ([source], [scopeSql]).
String _bumpSql(String source, String scopeSql) =>
    'INSERT OR IGNORE INTO input_revision(source, scope, rev) '
    'VALUES(${_q(source)}, $scopeSql, 0); '
    'UPDATE input_revision SET rev = rev + 1 '
    'WHERE source = ${_q(source)} AND scope = $scopeSql;';

/// Creates `input_revision` and the AFTER INSERT/UPDATE/DELETE triggers for
/// every catalogued table. Idempotent (CREATE ... IF NOT EXISTS); a table that
/// does not exist yet is skipped and picked up by the next open's repair pass.
///
/// The statements run inside `_ldbPrivCreateInputRev` (schema.dart), the one
/// pinned DDL member for input-revision triggers (p21 write-seam guard).
Future<void> createInputRevision(DatabaseExecutor db) =>
    LocalDb.createInputRevTriggers(db);

/// `CREATE TABLE` for `input_revision`.
const String kCreateInputRevisionTable =
    'CREATE TABLE IF NOT EXISTS input_revision ('
    'source TEXT NOT NULL, scope TEXT NOT NULL, rev INTEGER NOT NULL, '
    'PRIMARY KEY(source, scope))';

/// The CREATE TRIGGER statements still missing, given the tables and triggers
/// that exist now. Pure: it decides, the caller runs them.
List<String> inputRevisionTriggerSql(
    Set<String> tables, Set<String> triggers) {
  final out = <String>[];
  for (final spec in kInputCatalogue) {
    if (spec.kind != InputKind.table) continue;
    final global = spec.granularity == InputGranularity.global;
    for (final t in spec.tables) {
      if (!tables.contains(t.name)) continue;
      String scope(String row) => global
          ? "''"
          : "COALESCE(${t.dayExpr!.replaceAll('{r}', row)}, '')";
      final base = 'ir_${spec.id}_${t.name}';
      final of = t.updateOf.isEmpty ? '' : ' OF ${t.updateOf.join(', ')}';
      void make(String suffix, String event, String body,
          {String when = '', String cols = ''}) {
        if (triggers.contains('${base}_$suffix')) return;
        out.add('CREATE TRIGGER IF NOT EXISTS ${base}_$suffix '
            'AFTER $event$cols ON ${t.name} $when BEGIN $body END');
      }

      make('ai', 'INSERT', _bumpSql(spec.id, scope('NEW')));
      make('au', 'UPDATE', _bumpSql(spec.id, scope('NEW')), cols: of);
      if (!global) {
        // A row that moved days changes both days.
        make('au_old', 'UPDATE', _bumpSql(spec.id, scope('OLD')),
            when: 'WHEN ${scope('OLD')} IS NOT ${scope('NEW')}', cols: of);
      }
      make('ad', 'DELETE', _bumpSql(spec.id, scope('OLD')));
    }
  }
  return out;
}

/// Adds 1 to the revision of ([source], [scope]); [scope] is a day label or ''.
/// For non-table setters (profile, policies).
Future<void> bumpInputRev(String source, String scope,
    {DatabaseExecutor? db}) async {
  final ex = db ?? await LocalDb.instance;
  await ex.execute(
    'INSERT OR IGNORE INTO input_revision(source, scope, rev) VALUES(?, ?, 0)',
    [source, scope],
  );
  await ex.execute(
    'UPDATE input_revision SET rev = rev + 1 WHERE source = ? AND scope = ?',
    [source, scope],
  );
}

/// Revisions of [sources] for the global scope '' and every day label in
/// [fromDay]..[toDay] inclusive. `decoded` is summed from `input_rev` buckets
/// per day.
Future<InputRevSnapshot> inputRevSnapshot(
  Iterable<String> sources, {
  required String fromDay,
  required String toDay,
  DatabaseExecutor? db,
}) async {
  final ex = db ?? await LocalDb.instance;
  final out = <String, Map<String, int>>{};
  final plain = sources.where((s) => s != 'decoded').toList();
  if (plain.isNotEmpty) {
    final rows = await ex.rawQuery(
      'SELECT source, scope, rev FROM input_revision '
      'WHERE source IN (${List.filled(plain.length, '?').join(', ')}) '
      "AND (scope = '' OR (scope >= ? AND scope <= ?))",
      [...plain, fromDay, toDay],
    );
    for (final r in rows) {
      (out[r['source'] as String] ??= <String, int>{})[r['scope'] as String] =
          (r['rev'] as num).toInt();
    }
  }
  if (sources.contains('decoded')) {
    // One day of slack each side so the SQL day filter, not the bucket
    // arithmetic, decides which days are in range (DST, zone changes).
    final lo = DateTime.parse(fromDay).subtract(const Duration(days: 1));
    final hi = DateTime.parse(toDay).add(const Duration(days: 2));
    final rows = await ex.rawQuery(
      "SELECT strftime('%Y-%m-%d', bucket * 900, 'unixepoch', 'localtime') "
      'AS d, SUM(rev) AS rev FROM input_rev '
      'WHERE bucket >= ? AND bucket < ? GROUP BY d',
      [
        DateTime(lo.year, lo.month, lo.day).millisecondsSinceEpoch ~/ 900000,
        DateTime(hi.year, hi.month, hi.day).millisecondsSinceEpoch ~/ 900000,
      ],
    );
    final m = out['decoded'] = <String, int>{};
    for (final r in rows) {
      final d = r['d'] as String?;
      if (d == null || d.compareTo(fromDay) < 0 || d.compareTo(toDay) > 0) {
        continue;
      }
      m[d] = (r['rev'] as num).toInt();
    }
  }
  return out;
}
