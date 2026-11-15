// Controlled coordination measurement, not a phone benchmark. The same three
// stored-data replies each take 50ms before and after the structural change.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'backup/backup_support.dart';
import 'support/live_guide_harness.dart';
class _Measured extends GuideFakeRepo {
  Future<Map<String, dynamic>> reply() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return {};
  }
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) => reply();
  @override
  Future<Map<String, dynamic>> getDayWear(String day) => reply();
  @override
  Future<Map<String, dynamic>> getDayHrv(String day) => reply();
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure Review stored reads over the same delayed replies', () async {
    final env = await BackupEnv.create('structural_measure.db');
    try {
      await LocalDb.instance;
      final watch = Stopwatch()..start();
      final data = await TimelineData.load(_Measured(), want: '2026-11-13');
      expect(data.day, '2026-11-13');
      // ignore: avoid_print
      print('REVIEW_CONTROLLED_LOAD_MS=${watch.elapsedMilliseconds}');
    } finally { await env.dispose(); }
  });
}
