// WHY: Review formerly waited for every source in sequence. All independent
// sources must start while the first one is blocked, and their costs are named.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'backup/backup_support.dart';
import 'support/live_guide_harness.dart';

class _Reads extends GuideFakeRepo {
  final gate = Completer<void>();
  final started = <String>{};
  Future<Map<String, dynamic>> read(String name) async {
    started.add(name);
    await gate.future;
    return {};
  }
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) => read('timeline');
  @override
  Future<Map<String, dynamic>> getDayWear(String day) => read('wear');
  @override
  Future<Map<String, dynamic>> getDayHrv(String day) => read('hrv');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('review starts independent reads together and reports costs', () async {
    final env = await BackupEnv.create('structural_review_reads.db');
    try {
      await LocalDb.instance;
      final repo = _Reads();
      final future = TimelineData.load(repo, want: '2026-11-13');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repo.started, {'timeline', 'wear', 'hrv'});
      repo.gate.complete();
      final data = await future;
      expect(data.day, '2026-11-13');
      expect(data.readMillis.keys, containsAll(['heart rate, movement and sleep',
        'wear coverage', 'journal fields', 'calculation timestamp', 'wake timeline']));
      // These are real elapsed costs of the fake repository + real empty SQL
      // store. They diagnose coordination; they are not phone benchmarks.
      // ignore: avoid_print
      print('Review load ${data.loadMillis}ms; per read ${data.readMillis}');
    } finally { await env.dispose(); }
  });
}
