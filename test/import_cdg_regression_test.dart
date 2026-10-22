import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'support/frozen_day_result_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(dropDb);
  test('large checkpoint and bounded SQL projection', () async {
    final db = await freshDb('cdg_checkpoint.db');
    final state = Uint8List.fromList(
      List.generate(3 * 1024 * 1024 + 17, (i) => i % 251),
    );
    await db.insert('day_checkpoint', {
      'day_id': '2026-07-01',
      'algo_version': 104,
      'fmt': 1,
      'ctx_sig': 'sig',
      'cp_rec_ts': 100,
      'rev_vec': state,
      'state': state,
      'computed_at': 9,
    });
    final cp = (await LocalDb.dayCheckpoint('2026-07-01', 104))!;
    expect(cp.state, state);
    expect(cp.revVec, state);
    final source = File(
      'lib/data/db/derive_store.dart',
    ).readAsStringSync().split('Future<bool>').first;
    expect(source, contains('length(state)'));
    expect(source, contains('length(rev_vec)'));
    expect(source, isNot(contains("db.query(")));
    expect(source, isNot(contains('SELECT *')));
    expect(source, contains('substr('));
  });
}
