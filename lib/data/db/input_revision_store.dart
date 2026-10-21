// input_revision_store.dart — per-input revisions (design 06 phase 1c).
//
// `input_revision(source, scope, rev)`: one counter per catalogued input and
// scope (a local day label, or '' for a global input). Table inputs are bumped
// by AFTER INSERT/UPDATE/DELETE triggers generated from `kInputCatalogue`;
// setter inputs (profile, policy) bump through [bumpInputRev]; `decoded` is the
// existing `input_rev` 15-minute buckets, summed per day on read.
//
// Rules: a revision only ever goes up while the store lives. `wipeAll` empties
// this table with everything else (no stamp survives a wipe, and the rows name
// every day with data), and a restore never copies a foreign file's revisions
// (the merged rows bump ours via triggers).
//
// The bump is UPSERT-free (INSERT OR IGNORE, then UPDATE rev = rev + 1):
// Android 8-10 ship a SQLite without ON CONFLICT DO UPDATE (D32 hit the same).
// Nothing here backfills, so it is cheap under iOS's CPU watchdog (invariant
// 11); a missing row reads as revision 0.

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:sqflite/sqflite.dart';

import '../../compute/groups/input_catalogue.dart';
import '../db.dart';

/// source -> scope -> revision. Absent means revision 0.
typedef InputRevSnapshot = Map<String, Map<String, int>>;

String _q(String s) => "'${s.replaceAll("'", "''")}'";

// Why not `INSERT OR IGNORE` + UPDATE: SQLite applies the OUTER statement's
// conflict policy to statements run by a trigger, so under the writers'
// `INSERT OR REPLACE` that OR IGNORE becomes a REPLACE and resets the counter
// to 0 before the UPDATE adds 1 (Sol r1, finding 1). A plain INSERT guarded by
// NOT EXISTS has no conflict for any outer policy to act on.
//
// [scopesSql] is a SELECT of the scopes to bump (a column named S).
String _bumpScopesSql(String source, String scopesSql) =>
    'INSERT INTO input_revision(source, scope, rev) '
    'SELECT ${_q(source)}, S, 0 FROM ($scopesSql) WHERE S IS NOT NULL '
    'AND NOT EXISTS (SELECT 1 FROM input_revision '
    'WHERE source = ${_q(source)} AND scope = S); '
    'UPDATE input_revision SET rev = rev + 1 WHERE source = ${_q(source)} '
    'AND scope IN (SELECT S FROM ($scopesSql));';

/// Creates `input_revision` and the triggers for every catalogued table.
/// Idempotent: a trigger whose text changed is dropped and recreated, one that
/// exists unchanged is left; a table that does not exist yet is skipped and
/// picked up by the next open's repair pass.
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

const String _createPrefix = 'CREATE TRIGGER IF NOT EXISTS ';

/// The wrist and charging toggles, as event-id pairs (a transition holds
/// until the next of its own pair).
List<List<int>> get _toggleKinds => [
      [proto.EventId.wristOn, proto.EventId.wristOff],
      [proto.EventId.chargingOn, proto.EventId.chargingOff],
    ];

/// The CREATE (and preceding DROP) statements still needed, given the tables
/// that exist now, each existing trigger's stored SQL by name, and each
/// table's unique-key column sets (primary key and unique indexes: what a
/// REPLACE would delete). Pure: it decides, the caller runs them.
List<String> inputRevisionTriggerSql(
  Set<String> tables,
  Map<String, String> triggers, {
  Map<String, List<List<String>>> keys = const {},
}) {
  final out = <String>[];
  for (final spec in kInputCatalogue) {
    if (spec.kind != InputKind.table) continue;
    final global = spec.granularity == InputGranularity.global;
    for (final t in spec.tables) {
      if (!tables.contains(t.name)) continue;
      String scope(String row) => global
          ? "''"
          : "COALESCE(${t.dayExpr!.replaceAll('{r}', row)}, '')";
      String cond(String row) =>
          t.when == null ? '1' : '(${t.when!.replaceAll('{r}', row)})';
      final base = 'ir_${spec.id}_${t.name}';
      final of = t.updateOf.isEmpty ? '' : ' OF ${t.updateOf.join(', ')}';

      // The scopes a change to row [row] reaches. [match] is a WHERE over an
      // alias `o` of the table when [row] is that alias (the row a REPLACE is
      // about to displace); null for NEW / OLD.
      String scopes(String row, {String? match}) {
        final from = match == null ? '' : ' FROM ${t.name} o WHERE $match';
        if (global) return "SELECT '' AS S";
        if (!t.spans) {
          // A row anchored in time that also describes earlier days (Colmi
          // temperature slots): those days too, for the rows that do.
          final lb = t.lookbackExpr;
          final back = lb == null
              ? ''
              : [
                  for (var k = 1; k <= t.lookbackDays; k++)
                    ' UNION SELECT ${lb.replaceAll('{r}', row).replaceAll('{k}', '$k')} '
                        'AS S$from'
                        '${match == null ? ' WHERE' : ' AND'} '
                        '${t.lookbackWhen!.replaceAll('{r}', row)}'
                ].join();
          return 'SELECT ${scope(row)} AS S$from$back';
        }
        // A transition holds until the next of its kind, so its change moves
        // every derived day from its own through that one (design 06 1c,
        // Sol r1 finding 4). No later transition: through the last derived
        // day. Only days with a day_result can hold a stamp.
        final ids = [for (final k in _toggleKinds) ...k].join(', ');
        final same = [
          for (final k in _toggleKinds)
            '($row.event_id IN (${k.join(', ')}) '
                'AND n.event_id IN (${k.join(', ')}))'
        ].join(' OR ');
        String dayOf(String r) => t.dayExpr!.replaceAll('{r}', r);
        final d0 = dayOf(row);
        final next = '(SELECT MIN(n.ts) FROM ${t.name} n '
            'WHERE n.device_id = $row.device_id AND n.ts > $row.ts '
            'AND ($same))';
        final d1 = 'CASE WHEN $row.event_id IN ($ids) THEN COALESCE('
            "strftime('%Y-%m-%d', $next, 'unixepoch', 'localtime'), "
            "'9999-12-31') ELSE $d0 END";
        // Not during a bulk restore: it bumps the union of the spans once
        // (endBulkSpans), instead of every row re-bumping all later days.
        return "SELECT COALESCE($d0, '') AS S$from UNION "
            'SELECT dr.day_id AS S FROM day_result dr'
            '${match == null ? '' : ', ${t.name} o'} WHERE '
            '${match == null ? '' : '($match) AND '}'
            'NOT EXISTS (SELECT 1 FROM input_rev_bulk) AND '
            'dr.day_id > $d0 AND dr.day_id <= $d1';
      }

      void make(String suffix, String event, String when, String body,
          {String cols = ''}) {
        final name = '${base}_$suffix';
        final create = '$_createPrefix$name '
            '$event$cols ON ${t.name} FOR EACH ROW '
            '${when.isEmpty ? '' : 'WHEN $when '}BEGIN $body END';
        final have = triggers[name];
        if (have != null) {
          if (have == 'CREATE TRIGGER ${create.substring(_createPrefix.length)}') {
            return;
          }
          out.add('DROP TRIGGER IF EXISTS $name');
        }
        out.add(create);
      }

      String bump(String row) => _bumpScopesSql(spec.id, scopes(row));

      make('ai', 'AFTER INSERT', cond('NEW'), bump('NEW'));
      make('au', 'AFTER UPDATE', '${cond('NEW')} OR ${cond('OLD')}', bump('NEW'),
          cols: of);
      if (!global) {
        // A row that moved days changes both days; a span row's old extent
        // changes whenever it changes at all.
        make(
            'au_old',
            'AFTER UPDATE',
            '${cond('OLD')} AND '
                '${t.spans || t.lookbackExpr != null ? '1' : '${scope('OLD')} IS NOT ${scope('NEW')}'}',
            bump('OLD'),
            cols: of);
      }
      make('ad', 'AFTER DELETE', cond('OLD'), bump('OLD'));
      final ks = keys[t.name] ?? const <List<String>>[];
      if (!global && ks.isNotEmpty) {
        // REPLACE deletes the row it displaces without firing a DELETE
        // trigger (recursive_triggers is off), so the day it leaves is bumped
        // here, before the insert, while the old row still exists (Sol r1,
        // finding 2). Skipped where the old row is on the same day: the AFTER
        // INSERT bump already covers it.
        final match = ks
            .map((k) => '(${k.map((c) => 'o.$c = NEW.$c').join(' AND ')})')
            .join(' OR ');
        final old = scopes('o', match: match);
        make(
            'bi',
            'BEFORE INSERT',
            cond('NEW'),
            _bumpScopesSql(
                spec.id,
                // DISTINCT: several rows can be displaced (one per unique key).
                t.spans
                    ? 'SELECT DISTINCT S FROM ($old)'
                    : 'SELECT DISTINCT S FROM ($old) '
                        'WHERE S IS NOT ${scope('NEW')}'));
      }
    }
  }
  return out;
}

/// What a REPLACE into each of [tables] would delete: the primary key and
/// every unique index, as column lists (the BEFORE INSERT trigger reads the
/// displaced row through them). A unique EXPRESSION index cannot be matched
/// column by column, so a catalogued table that has one is refused (asserts;
/// no catalogued table has one today) rather than silently skipped.
Future<Map<String, List<List<String>>>> inputRevisionKeys(
    DatabaseExecutor db, Iterable<String> tables) async {
  final keys = <String, List<List<String>>>{};
  for (final t in tables) {
    final info = await db.rawQuery('PRAGMA table_info($t)');
    final pk = [
      for (final c in info)
        if (((c['pk'] as num?) ?? 0) > 0) c
    ]..sort((a, b) => (a['pk'] as num).compareTo(b['pk'] as num));
    final sets = <List<String>>[
      if (pk.isNotEmpty) [for (final c in pk) c['name'] as String],
    ];
    for (final ix in await db.rawQuery('PRAGMA index_list($t)')) {
      if (((ix['unique'] as num?) ?? 0) != 1) continue;
      final cols = [
        for (final c in await db.rawQuery('PRAGMA index_info(${ix['name']})'))
          c['name'] as String?
      ];
      assert(cols.isNotEmpty && !cols.contains(null),
          'input revision: $t has a unique expression index (${ix['name']}); '
          'the displaced-row trigger cannot match it');
      if (cols.isEmpty || cols.contains(null)) continue;
      // A non-integer PRIMARY KEY also shows up as an autoindex: once.
      final set = cols.cast<String>();
      if (!sets.any((k) => k.join(',') == set.join(','))) sets.add(set);
    }
    keys[t] = sets;
  }
  return keys;
}

/// Starts a bulk write of wrist/charging transitions inside [txn]: until
/// [endBulkSpans], the per-row triggers leave the later-day invalidation to it
/// (Sol r2 finding 2: per-row, a chronological restore into a target with
/// derived history bumps every later day once per transition). The flag row
/// lives in the transaction, so a rollback or a crash clears it.
Future<void> beginBulkSpans(DatabaseExecutor txn) =>
    txn.execute('INSERT INTO input_rev_bulk(flag) VALUES (1)');

/// Ends [beginBulkSpans] and bumps `events` once for every derived day after
/// the local day of [fromTs], the earliest transition written or displaced.
/// Conservative: transitions can reach as far as the last derived day, and
/// finding where each one stops is the cost this avoids. Null = nothing
/// written.
Future<void> endBulkSpans(DatabaseExecutor txn, int? fromTs) async {
  await txn.execute('DELETE FROM input_rev_bulk');
  if (fromTs == null) return;
  await txn.execute(
      "INSERT INTO input_revision(source, scope, rev) "
      "SELECT 'events', S, 0 FROM (SELECT DISTINCT day_id AS S FROM day_result "
      "WHERE day_id > strftime('%Y-%m-%d', ?, 'unixepoch', 'localtime')) "
      "WHERE NOT EXISTS (SELECT 1 FROM input_revision "
      "WHERE source = 'events' AND scope = S)",
      [fromTs]);
  await txn.execute(
      "UPDATE input_revision SET rev = rev + 1 WHERE source = 'events' "
      "AND scope IN (SELECT day_id FROM day_result WHERE day_id > "
      "strftime('%Y-%m-%d', ?, 'unixepoch', 'localtime'))",
      [fromTs]);
}

/// Adds 1 to the revision of ([source], [scope]); [scope] is a day label or ''.
/// For non-table setters (profile, policies).
Future<void> bumpInputRev(String source, String scope,
    {DatabaseExecutor? db}) async {
  final ex = db ?? await LocalDb.instance;
  // Same non-conflicting insert as the triggers (see _bumpScopesSql).
  await ex.execute(
    'INSERT INTO input_revision(source, scope, rev) SELECT ?, ?, 0 '
    'WHERE NOT EXISTS (SELECT 1 FROM input_revision '
    'WHERE source = ? AND scope = ?)',
    [source, scope, source, scope],
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

/// The zone as the stamps see it: its name, its offset now, and its offsets at
/// four fixed instants (15 Jan and 15 Jul, last year and this). The name and
/// current offset alone cannot tell Denver from Phoenix in winter (both MST,
/// -420), yet July 1 06:30 UTC is a different local date in each. No IANA id
/// is available in-process on every isolate, so the zone's own rules are
/// sampled instead. [offsetAt] defaults to the process's local zone.
String inputZoneKey(String name, {DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  return inputZoneKeyOf(name, t.toLocal().timeZoneOffset.inMinutes, [
    for (final y in [t.year - 1, t.year])
      for (final m in [1, 7])
        DateTime.utc(y, m, 15, 12).toLocal().timeZoneOffset.inMinutes,
  ]);
}

/// The key from a zone's [name], its offset now and its sampled offsets
/// (minutes). Pure: [inputZoneKey] reads them off the process's zone.
String inputZoneKeyOf(String name, int nowMinutes, List<int> sampleMinutes) =>
    '$name|$nowMinutes|${sampleMinutes.join(',')}';

/// Records the zone the app is running in ([zoneKey], default
/// [inputZoneKey] of the process's zone) and bumps the global `zone` input
/// when it differs from the last one seen. Returns whether it bumped. The
/// first observation only records: there is nothing earlier to have been
/// stamped under.
///
/// The cursor read, its write and the bump are one transaction (Sol r2
/// finding 4): a failure leaves both unchanged, so the next observation sees
/// the old cursor and retries. Throws on failure; the caller logs it.
///
/// INTERIM for design 01 (see the `zone` entry in input_catalogue.dart): day
/// labels come from the phone's current zone, so a zone change moves labels
/// the stored stamps were taken under. DST is a change of name and offset, so
/// it counts.
Future<bool> observeInputZone(
    {String? zoneKey, DatabaseExecutor? db}) async {
  final key = zoneKey ?? inputZoneKey(DateTime.now().timeZoneName);
  final ex = db ?? await LocalDb.instance;
  Future<bool> body(DatabaseExecutor x) async {
    final seen = await x.query('sync_cursor',
        columns: ['value'],
        where: 'name = ?',
        whereArgs: [kObservedZoneCursor]);
    final last = seen.isEmpty ? null : seen.first['value'] as String?;
    if (last == key) return false;
    await x.insert(
      'sync_cursor',
      {
        'name': kObservedZoneCursor,
        'value': key,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (last == null) return false;
    await bumpInputRev('zone', '', db: x);
    return true;
  }

  return ex is Database ? ex.transaction(body) : body(ex);
}

/// The `sync_cursor` row holding the last zone [observeInputZone] saw.
const String kObservedZoneCursor = 'observed_zone';
