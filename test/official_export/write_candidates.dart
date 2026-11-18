// Fork-side: builds the rich fixture and writes the candidate files the
// receiver probes import. Copied to write_candidates_test.dart by
// harness/run_receiver_scenarios.sh.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'candidate_stub.dart';
import 'rich_fixture.dart';
import 'support.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart' hide oldestMappedExactSec;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('write candidates', () async {
    final out = Directory(
      Platform.environment['CANDIDATES_DIR'] ?? 'build/official_probe/candidates',
    )..createSync(recursive: true);
    final fx = await RichFixture.build();
    try {
      expect(fx.unfilled, isEmpty);
      for (final (name, path) in [
        ('naive.db', await naiveCopyCandidate(fx, name: 'naive.db')),
        ('policy.db', (await mapOfficialSnapshot(snapshotPath: fx.forkPath, outputPath: '${File(fx.forkPath).parent.path}/policy.db', factory: databaseFactoryFfi, calendar: const FixedOffsetCalendar(0))).path),
        ('nocursor.db', await policyCandidate(fx, name: 'nocursor.db', withCursor: false)),
        ('units_naive.db', await naiveCopyCandidate(fx, name: 'units_naive.db')),
        ('units_control.db', (await mapOfficialSnapshot(snapshotPath: fx.forkPath, outputPath: '${File(fx.forkPath).parent.path}/units_control.db', factory: databaseFactoryFfi, calendar: const FixedOffsetCalendar(0))).path),
      ]) {
        File(path).copySync('${out.path}/$name');
      }
    } finally {
      await fx.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
