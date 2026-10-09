// P2.1 guard tests (a) and (b), design 02 step 2, section 4.2.
//
// (a) Every write to `day_result` or `baselines` sits inside an allow-listed
//     `LocalDb` method. The revision identity itself comes from triggers, so it
//     does not depend on this. What depends on it is the RULE: the frozen-row
//     check, the compare-and-set, the value-identical re-encode. A second writer
//     elsewhere bypasses it. At HEAD there is exactly one such writer,
//     `DemoDataGenerator.purge`, and the seam is closed by moving it into
//     `LocalDb.purgeDemoRows`.
// (b) `UPDATE day_result` appears in exactly one place, the value-identical
//     re-encode in `reencodeLegacyDayResults`, setting only `payload_json`
//     under a `payload_json = ?` compare-and-set.
//
// The scan is `test/step2/support/write_seam_scan.dart`. Its own behaviour is
// pinned first, on synthetic sources, so a scanner that stopped seeing writes
// would fail here instead of letting the real scan pass vacuously.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/write_seam_scan.dart';

/// The only places allowed to write each table: `Class.member` to the verbs it
/// may use. The migration ladder's one-time `derived_day` copy runs inside
/// `_open`, before schema 71 and its triggers exist, and is allowed for that
/// reason only.
const _allowed = <String, Map<String, Set<String>>>{
  'day_result': {
    'LocalDb.putDayResult': {'insert'},
    'LocalDb._open': {'insert'},
    'LocalDb.deleteDays': {'delete'},
    'LocalDb.reencodeLegacyDayResults': {'update'},
    'LocalDb.purgeDemoRows': {'delete'},
  },
  'baselines': {
    'LocalDb.putBaseline': {'insert'},
    'LocalDb.updateBaseline': {'insert'},
    'LocalDb.touchBaseline': {'update'},
  },
};

const _dbFile = 'lib/data/db.dart';

/// Writers that name their table by variable or interpolation, so the literal
/// scan cannot see which tables they reach. Each is pinned by (file, member)
/// with why it is acceptable. `wipeAll` and `_mergeFromDbFileBody` DO reach
/// `day_result` and `baselines`, by design, and are the only ones that do.
const _pinnedDynamicWriters = <String, String>{
  'lib/data/db.dart LocalDb.wipeAll':
      'empties every table from sqlite_master (the honest "delete everything")',
  'lib/data/db.dart LocalDb._mergeFromDbFileBody':
      'restore and salvage: walks _restoreTables / _salvageTables',
  'lib/data/db.dart LocalDb.deleteDays':
      'deleteByIn(txn, <literal table>, ...) helper plus the fixed session '
      'child-table list',
  'lib/data/db.dart LocalDb.exportDaysDb':
      'writes the EXPORT file, not the store; fixed table list',
  'lib/data/db.dart LocalDb.pruneSupersededIntermediates':
      'fixed list of derived-intermediate tables (not day_result)',
  'lib/data/db.dart LocalDb._rekeyTableByDevice':
      'schema-ladder re-key of the decoded tables, fixed names',
  'lib/data/db.dart LocalDb._rekeyByDeviceIdV51':
      'schema-ladder re-key of the decoded tables, fixed names',
};

/// Declarations of plain-string lists that mention `day_result` or `baselines`.
/// The two merge lists feed the dynamic writer; the coach list is a DENY list;
/// `_nightBlocks` names payload keys (`baselines` is a bundle block there).
const _pinnedTableLists = <String>{
  'lib/data/db.dart LocalDb._restoreTables',
  'lib/data/db.dart LocalDb._salvageTables',
  'lib/coach/coach_db.dart CoachDb.reservedTableNames',
  'lib/compute/sleep_blank.dart <top>',
};

/// The text of member [name] in comment-blanked [code]: signature through the
/// closing brace.
String _body(String code, String name) {
  final m = RegExp('\\n  static [^\\n]*\\b$name\\s*\\(').firstMatch(code);
  expect(m, isNotNull, reason: 'no static member $name');
  final open = code.indexOf('{', code.indexOf(')', m!.end));
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}' && --depth == 0) return code.substring(m.start, i + 1);
  }
  fail('unbalanced braces in $name');
}

/// The quoted items of the list literal assigned to static field [name].
Set<String> _listItems(String code, String name) {
  final m = RegExp('\\b$name\\s*=\\s*(?:const\\s*)?\\[').firstMatch(code);
  expect(m, isNotNull, reason: 'no list $name');
  final end = code.indexOf('];', m!.end);
  return {
    for (final i in RegExp('[\'"](\\w+)[\'"]').allMatches(code.substring(m.end, end)))
      i[1]!,
  };
}

Map<String, List<WriteSite>> _scanLib() {
  final out = <String, List<WriteSite>>{};
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final sites = scanWriters(f.readAsStringSync());
    if (sites.isNotEmpty) out[f.path] = sites;
  }
  return out;
}

bool _isAllowed(String path, WriteSite s) =>
    path == _dbFile && (_allowed[s.table]?[s.member]?.contains(s.verb) ?? false);

void main() {
  group('the scanner sees what it guards', () {
    test('API writes, raw SQL writes and the deleteByIn helper', () {
      const src = '''
class LocalDb {
  static Future<void> a(Database db) async {
    await db.insert('day_result', {'k': 1});
    await db.update('baselines', {'updated_at': 1}, where: 'key = ?');
    await txn.delete('day_result', where: 'day_id = ?');
    await deleteByIn(txn, 'day_result', 'day_id', ids);
    await db.rawInsert('INSERT OR REPLACE INTO baselines (key) VALUES (?)');
    await db.execute('UPDATE day_result SET payload_json = ?');
    await db.rawDelete('DELETE FROM baselines WHERE key = ?');
  }
}
''';
      final sites = scanWriters(src);
      expect(
        [for (final s in sites) '${s.verb} ${s.table}'],
        [
          'insert day_result',
          'update baselines',
          'delete day_result',
          'delete day_result',
          'insert baselines',
          'update day_result',
          'delete baselines',
        ],
      );
      expect({for (final s in sites) s.member}, {'LocalDb.a'});
    });

    test('statements split across adjacent string literals are one statement',
        () {
      const src = '''
class LocalDb {
  static Future<void> split(Database db) async {
    await db.execute(
      'INSERT OR IGNORE INTO '
      'day_result (day_id) VALUES (1)',
    );
  }
}
''';
      expect(scanWriters(src), hasLength(1));
    });

    test('reads, comments and other tables are not writes', () {
      const src = '''
class LocalDb {
  // await db.insert('day_result', {});
  /* db.execute('DELETE FROM day_result') */
  static Future<void> reads(Database db) async {
    await db.query('day_result');
    await db.rawQuery('SELECT * FROM baselines');
    await db.insert('day_result_other', {});
    await db.insert('metric_series', {});
    // CREATE TRIGGER t AFTER INSERT ON day_result BEGIN SELECT 1; END
  }
  static Future<void> trig(Database db) async {
    await db.execute('CREATE TRIGGER t AFTER INSERT ON day_result '
        'BEGIN INSERT OR REPLACE INTO row_rev (kind) VALUES (1); END');
  }
}
''';
      expect(scanWriters(src), isEmpty);
    });

    test('the enclosing member survives named-parameter braces and closures',
        () {
      const src = '''
class LocalDb {
  static Future<bool> withParams({
    required String a,
    Set<String> b = const {},
  }) async {
    return db.transaction((txn) async {
      await txn.insert('day_result', {'a': a});
      return true;
    });
  }

  static Future<void> arrow(Database db) =>
      db.delete('baselines');
}
void topLevel(Database db) {
  db.delete('day_result');
}
''';
      expect(
        [for (final s in scanWriters(src)) s.member],
        ['LocalDb.withParams', 'LocalDb.arrow', 'topLevel'],
      );
    });

    test('updatedColumns reads the SET list of an API update and of raw SQL',
        () {
      final api = scanWriters(
        "class A { void f() { txn.update('day_result', "
        "{'payload_json': x, 'finalized': 1}, where: 'a = ?'); } }",
      ).single;
      expect(updatedColumns(api), {'payload_json', 'finalized'});
      final raw = scanWriters(
        "class A { void f() { db.execute('UPDATE day_result SET payload_json "
        "= ?, computed_at = ? WHERE day_id = ?'); } }",
      ).single;
      expect(updatedColumns(raw), {'payload_json', 'computed_at'});
    });
  });

  group('every valid SQL spelling of a write is seen (Sol r1)', () {
    List<String> hits(String sql) => [
      for (final w in scanWriters(
        "class A { void f() { db.execute('$sql'); } }",
      ))
        '${w.verb} ${w.table}',
    ];

    test('quoted identifiers: double quotes, backticks, square brackets, '
        'schema prefix', () {
      expect(hits('UPDATE "day_result" SET a = 1'), ['update day_result']);
      expect(hits('UPDATE `day_result` SET a = 1'), ['update day_result']);
      expect(hits('UPDATE [day_result] SET a = 1'), ['update day_result']);
      expect(hits('UPDATE "main"."day_result" SET a = 1'),
          ['update day_result']);
      expect(hits('update main.baselines set a = 1'), ['update baselines']);
      expect(hits('INSERT INTO "baselines" (key) VALUES (1)'),
          ['insert baselines']);
      expect(hits('REPLACE INTO [baselines] (key) VALUES (1)'),
          ['insert baselines']);
      expect(hits('DELETE FROM `day_result` WHERE 1'), ['delete day_result']);
      expect(hits('DELETE FROM "main"."baselines"'), ['delete baselines']);
    });

    test('UPDATE OR <conflict> and INSERT OR <conflict>', () {
      for (final c in const ['REPLACE', 'ROLLBACK', 'ABORT', 'FAIL', 'IGNORE']) {
        expect(hits('UPDATE OR $c day_result SET a = 1'), ['update day_result'],
            reason: c);
        expect(hits('update or ${c.toLowerCase()} "baselines" set a = 1'),
            ['update baselines'],
            reason: c);
        expect(hits('INSERT OR $c INTO "day_result" (day_id) VALUES (1)'),
            ['insert day_result'],
            reason: c);
      }
    });

    test('a similarly named table is not one of ours', () {
      expect(hits('UPDATE "day_result_other" SET a = 1'), isEmpty);
      expect(hits('UPDATE my_baselines SET a = 1'), isEmpty);
      expect(hits('DELETE FROM [baselines_old]'), isEmpty);
      expect(hits('UPDATE "day_resultx" SET a = 1'), isEmpty);
    });

    test('the SET list of a quoted UPDATE OR ... is read for guard (b)', () {
      final site = scanWriters(
        'class A { void f() { db.execute(\'UPDATE OR IGNORE "day_result" SET '
        '"payload_json" = ?, `finalized` = 1 WHERE payload_json = ?\'); } }',
      ).single;
      expect(updatedColumns(site), {'payload_json', 'finalized'});
    });
  });

  group('dynamic writers are pinned by name (Sol r1)', () {
    test('a write whose table is a variable is flagged', () {
      const src = '''
class LocalDb {
  static Future<void> sneaky(Database db, String t) async {
    await db.insert(t, {'a': 1});
    await db.delete(
      t,
    );
    await db.rawDelete('DELETE FROM \$t');
  }
}
''';
      expect(
        [for (final w in scanDynamicWriters(src)) w.member],
        ['LocalDb.sneaky', 'LocalDb.sneaky', 'LocalDb.sneaky'],
      );
    });

    test('literal-table writes and plain List.insert are not dynamic', () {
      const src = '''
class A {
  void f(Database db, List<int> xs) {
    db.insert('journal', {});
    xs.insert(0, 1);
  }
}
''';
      expect(scanDynamicWriters(src), isEmpty);
    });

    test('a table-name list naming day_result or baselines is flagged '
        'outside the pinned declarations', () {
      const src = '''
class A {
  static const List<String> _mine = ['journal', 'day_result'];
  static final Set<String> _also = {'baselines'};
  static const List<String> _fine = ['journal'];
}
''';
      expect(
        [for (final l in scanTableLists(src)) l.member],
        ['A._mine', 'A._also'],
      );
    });

    test('every dynamic writer in lib/ is one of the pinned ones', () {
      final found = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final w in scanDynamicWriters(f.readAsStringSync())) {
          found.add('${f.path} ${w.member}');
        }
      }
      expect(
        found.difference(_pinnedDynamicWriters.keys.toSet()),
        isEmpty,
        reason: 'a new writer that names its table by variable can reach '
            'day_result or baselines without the literal scan seeing it',
      );
      expect(
        _pinnedDynamicWriters.keys.toSet().difference(found),
        isEmpty,
        reason: 'a pinned writer no longer exists: drop it from the pin list',
      );
    });

    test('the two that DO reach the tables are fed only by the pinned lists',
        () {
      final db = File(_dbFile).readAsStringSync();
      final code = blankComments(db);
      // wipeAll enumerates sqlite_master, so it covers every table by design.
      final wipe = _body(code, 'wipeAll');
      expect(wipe, contains('sqlite_master'));
      expect(wipe, contains('.delete(t)'));
      // The merge walks the restore list, and both pinned lists name the two.
      final merge = _body(code, '_mergeFromDbFileBody');
      expect(merge, contains('only ?? tables'));
      expect(RegExp(r'const\s+tables\s*=\s*_restoreTables').hasMatch(merge),
          isTrue);
      for (final list in const ['_restoreTables', '_salvageTables']) {
        final items = _listItems(code, list);
        expect(items, containsAll(['day_result', 'baselines']), reason: list);
      }
    });

    test('no other table list in lib/ names day_result or baselines', () {
      final named = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final l in scanTableLists(f.readAsStringSync())) {
          named.add('${f.path} ${l.member}');
        }
      }
      expect(named, _pinnedTableLists,
          reason: 'a new list of table names that includes day_result or '
              'baselines is a new way to reach them dynamically');
    });
  });

  group('(a) no writer outside the allow-listed LocalDb methods', () {
    test('every write to day_result or baselines is allow-listed', () {
      final offenders = <String>[];
      _scanLib().forEach((path, sites) {
        for (final s in sites) {
          if (!_isAllowed(path, s)) offenders.add('$path: $s');
        }
      });
      expect(
        offenders,
        isEmpty,
        reason:
            'a new writer bypasses the frozen-row rule and the write seam; '
            'route it through a LocalDb method and allow-list that method here',
      );
    });

    test('every allow-listed writer actually writes (the list is not stale)',
        () {
      final found = <String>{};
      for (final s in _scanLib()[_dbFile] ?? const <WriteSite>[]) {
        found.add('${s.table} ${s.member} ${s.verb}');
      }
      final missing = <String>[
        for (final t in _allowed.entries)
          for (final m in t.value.entries)
            for (final v in m.value)
              if (!found.contains('${t.key} ${m.key} $v'))
                '${t.key} ${m.key} $v',
      ];
      expect(missing, isEmpty);
    });

    test('the demo delete lives in LocalDb and DemoDataGenerator calls it', () {
      final demo = File('lib/demo/demo_data_generator.dart').readAsStringSync();
      expect(
        scanWriters(demo),
        isEmpty,
        reason: 'DemoDataGenerator.purge wrote day_result directly',
      );
      expect(
        RegExp(r'LocalDb\s*\.\s*purgeDemoRows\s*\(').hasMatch(blankComments(demo)),
        isTrue,
        reason: 'purge must delegate the delete to LocalDb.purgeDemoRows',
      );
    });
  });

  group('(b) UPDATE day_result in exactly one place', () {
    test('one site, in reencodeLegacyDayResults, setting only payload_json',
        () {
      final updates = <(String, WriteSite)>[];
      _scanLib().forEach((path, sites) {
        for (final s in sites) {
          if (s.table == 'day_result' && s.verb == 'update') {
            updates.add((path, s));
          }
        }
      });
      expect(updates, hasLength(1), reason: '$updates');
      final (path, site) = updates.single;
      expect(path, _dbFile);
      expect(site.member, 'LocalDb.reencodeLegacyDayResults');
      expect(updatedColumns(site), {'payload_json'});
      expect(
        site.text,
        contains('payload_json = ?'),
        reason: 'the update must be a compare-and-set on the payload it read',
      );
    });
  });
}
