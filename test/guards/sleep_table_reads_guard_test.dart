// WHY: projection rows cannot supply stable ids or exact suppression/history.
// CLAIM(sleep-block-guard), phase2_5-spec §3.3. Synthetic sources pin the scan.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/db_source.dart';
import 'support/sleep_reads_scan.dart';

const _kept = <String,Set<String>>{
  'lib/data/db.dart': {'LocalDb.getSleepOverride','LocalDb.napEdits',
    'LocalDb.sleepOverrideDays','LocalDb.napEditDays','LocalDb.exportDaysDb',
    'LocalDb._mergeFromDbFileBody','LocalDb.exportFilteredCopy','LocalDb.dayInputSignature'},
  'lib/data/tracks_schema.dart': {'createTrackTables'},
  'lib/data/sleep_edit_store.dart': {'SleepEditStore.reuseMeasuredNightIfCurrent'},
  'lib/data/sleep_block_store.dart': {'SleepBlockStore.backfill','SleepBlockStore.absorb',
    'SleepBlockStore._project'},
};
bool allowed(String path,SleepReadSite site) =>
    _kept[path]?.contains(site.member) ?? false;
void main() {
  test('scanner finds query/FROM/JOIN including quotes, adjacent strings and parts', () {
    const source = '''
class Screen {
  void load(db) {
    db.query(('sleep_nap'));
    db.rawQuery('SELECT * FROM ' '"sleep_override"');
    db.rawQuery(r'SELECT * FROM main.[sleep_nap] n JOIN `sleep_override` o ON 1');
    // db.query('sleep_nap');
    db.query('sleep_nap_other');
    db.rawDelete('DELETE FROM sleep_nap WHERE day_id = ?');
  }
}
void _ldbGetSleepOverride(db) { db.query('sleep_nap'); }
''';
    final sites = scanSleepReads(source);
    expect(sites.map((s)=>(s.table,s.member)),[
      ('sleep_nap','Screen.load'),('sleep_override','Screen.load'),
      ('sleep_nap','Screen.load'),('sleep_override','Screen.load'),
      ('sleep_nap','LocalDb.getSleepOverride'),
    ]);
    expect(allowed('lib/ui2/screens/planted.dart',sites.first),isFalse);
    expect(allowed('lib/data/db.dart',sites.last),isTrue);
  });
  test('real tree reads only allow-listed projection-exact readers', () {
    final failures=<String>[];
    for (final file in Directory('lib').listSync(recursive:true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final path=canonDbPath(file.path);
      for (final s in scanSleepReads(file.readAsStringSync())) {
        if (!allowed(path,s)) failures.add('$path:${s.line} ${s.member} ${s.table}');
      }
    }
    expect(failures,isEmpty,reason:'route history/suppression readers through SleepBlockStore');
  });
}
