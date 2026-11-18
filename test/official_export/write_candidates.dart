// Fork-side: builds the rich fixture and writes the candidate files the
// receiver probes import. Copied to write_candidates_test.dart by
// harness/run_receiver_scenarios.sh.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'candidate_stub.dart';
import 'rich_fixture.dart';

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
        ('policy.db', await policyCandidate(fx, name: 'policy.db')),
        ('nocursor.db', await policyCandidate(fx, name: 'nocursor.db', withCursor: false)),
        ('units_naive.db', await naiveCopyCandidate(fx, name: 'units_naive.db')),
        ('units_control.db', await policyCandidate(fx, name: 'units_control.db', unitKeyControl: true)),
      ]) {
        File(path).copySync('${out.path}/$name');
      }
    } finally {
      await fx.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
