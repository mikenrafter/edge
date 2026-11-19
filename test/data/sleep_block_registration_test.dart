// WHY: G3 catches a new user table omitted from backup/salvage/issue slices.
// CLAIM(sleep-block-owner). Transport behavior is slice C.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
void main() {
  test('G3 sleep blocks are registered for restore, salvage and issue slices', () {
    expect(LocalDb.restoreTablesForTest,contains('sleep_block'));
    expect(LocalDb.salvageTablesForTest,contains('sleep_block'));
    expect(kSliceTables['sleep_block']?.$1,SliceKeep.all);
  });
}
