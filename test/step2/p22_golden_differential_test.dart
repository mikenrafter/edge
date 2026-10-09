// P2.2 PARITY ANCHOR (design 02 step 2, section 4.3, last bullet).
//
// This test is written to PASS on the code as it stood before P2.2 (HEAD
// 68e1f676) and to keep passing after it. It is the differential: every
// repository reader that touches a stored bundle is run on one seeded database
// and its output, as JSON text, must equal the output recorded from the
// pre-P2.2 code in test/step2/golden/p22_reader_outputs.json.
//
// Why it matters: P2.2 moves decoding into a worker, makes the cache hold a
// frozen compact graph and copies only what a reader returns. Any reader that
// ends up with a different value, a different key order, a compact curve map
// where a list used to be, or a number that changed type (1 vs 1.0) shows up
// here as a byte difference.
//
// Recording: `P22_WRITE_GOLDEN=1 TZ=UTC flutter test <this file>` rewrites the
// golden from whatever code is checked out. Only do that from a commit whose
// readers are known good (it was recorded at HEAD 68e1f676, before any P2.2
// change). Today's label is the one value that moves; it is replaced by
// `<TODAY>` in both directions. The seed uses fixed timestamps; the
// repository reads the real local date for "today", so the test records which
// label it ran under and skips if the date rolled over mid-run.
//
// Run with TZ=UTC (the repo's test convention); under another zone the local
// day windows differ and the golden does not apply, so the test skips.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/p22_support.dart';

const _name = 'p22_golden.db';
const _goldenPath = 'test/step2/golden/p22_reader_outputs.json';

Future<String> _run(Future<Object?> Function() read, String today) async {
  try {
    return jsonEncode(await read()).replaceAll(today, '<TODAY>');
  } catch (e) {
    return 'ERROR ${e.runtimeType}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  test('every reader returns exactly what the pre-P2.2 code returned', () async {
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      markTestSkipped('golden is recorded under TZ=UTC');
      return;
    }
    final today = p22Today();
    await p22SeedReaderDb(db, today);
    final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

    final got = <String, String>{};
    for (final day in [...p22Days, today]) {
      for (final e in p22DayReaders.entries) {
        final label = day == today ? '<TODAY>' : day;
        got['${e.key}($label)'] = await _run(() => e.value(repo, day), today);
      }
    }
    for (final e in p22GlobalReaders.entries) {
      got[e.key] = await _run(() => e.value(repo), today);
    }
    // A second pass over the same rows: whatever the cache did on the first
    // pass must not change an answer.
    for (final e in p22DayReaders.entries) {
      got['again:${e.key}($p22D1)'] = await _run(() => e.value(repo, p22D1), today);
    }

    if (p22Today() != today) {
      markTestSkipped('the local date rolled over during the run');
      return;
    }

    if (Platform.environment['P22_WRITE_GOLDEN'] == '1') {
      File(_goldenPath).writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(got)}\n',
      );
      return;
    }

    final want = (jsonDecode(File(_goldenPath).readAsStringSync()) as Map)
        .cast<String, String>();
    expect(got.keys.toList(), want.keys.toList(), reason: 'same readers, same order');
    for (final k in want.keys) {
      expect(got[k], want[k], reason: 'reader output changed: $k');
    }
    expect(
      want.values.where((v) => v.startsWith('ERROR')),
      isEmpty,
      reason: 'the anchor must not record a failing reader',
    );
    expect(
      want.values.where((v) => v.length > 200).length,
      greaterThan(15),
      reason: 'the anchor must hold real, non-trivial outputs',
    );
  });
}
