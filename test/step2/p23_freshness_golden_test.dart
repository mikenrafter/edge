// P2.3 PARITY ANCHOR (design 02 step 2, section 2 B5 and 5 P2.3).
//
// `LocalDb.refreshComputeFreshness` must produce exactly the freshness state it
// produces today. This test PASSES on the code before P2.3 and must keep
// passing after it: each scenario seeds a fresh database, runs the refresh, and
// compares the three rows it writes (`capture`, `today`, `crossday`, as stored
// text, `updated_at` aside) with test/step2/golden/p23_freshness_outputs.json,
// recorded from the pre-P2.3 code (the current code is the oracle).
//
// Scenarios: overnight/recovery/today found, early break, skipped days, flags
// (list and not a list), readiness from the column or the payload scalar,
// undecodable rows, raw reaching today, wake-only activity, crossday with and
// without `rolling`, served-version ceiling, the 30-day window.
//
// Recording: `P23_WRITE_GOLDEN=1 TZ=UTC flutter test <this file>`. Only from a
// commit whose refresh is known good (recorded at HEAD 847cbb0f). Day labels
// are relative to today and become `<D0>`, `<D1>` ... in both directions; the
// one raw rec_ts becomes `<RAW>`. Under another timezone the test skips.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p23_support.dart';

const _name = 'p23_golden.db';
const _goldenPath = 'test/step2/golden/p23_freshness_outputs.json';

String _tokenise(String text, int? raw) {
  var out = text;
  for (var i = 40; i >= 0; i--) {
    out = out.replaceAll(p23Day(i), '<D$i>');
  }
  if (raw != null) out = out.replaceAll('$raw', '<RAW>');
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  setUp(() => BundleStore.debugResetShared());
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  test('every scenario writes exactly the freshness the pre-P2.3 code wrote',
      () async {
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      markTestSkipped('golden is recorded under TZ=UTC');
      return;
    }
    final today = p23Day(0);
    final got = <String, Map<String, String?>>{};
    for (final entry in p23Scenarios().entries) {
      final db = await p21Fresh(_name);
      final raw = await entry.value(db);
      await LocalDb.refreshComputeFreshness();
      final rows = await p23FreshnessRows(db);
      got[entry.key] = {
        for (final r in rows.entries)
          r.key: r.value == null ? null : _tokenise(r.value!, raw),
      };
      await LocalDb.close();
    }
    if (p23Day(0) != today) {
      markTestSkipped('the local date rolled over during the run');
      return;
    }

    if (Platform.environment['P23_WRITE_GOLDEN'] == '1') {
      File(_goldenPath).writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(got)}\n',
      );
      return;
    }

    final want = (jsonDecode(File(_goldenPath).readAsStringSync()) as Map)
        .map((k, v) => MapEntry(k as String, (v as Map).cast<String, String?>()));
    expect(got.keys.toList(), want.keys.toList(), reason: 'same scenarios');
    for (final k in want.keys) {
      expect(got[k], want[k], reason: 'freshness changed: $k');
    }
    // The anchor must hold real answers, not a table of nulls.
    expect(want.values.where((m) => m['today'] == null), isEmpty);
    final states = want.values
        .map((m) => jsonDecode(m['today']!) as Map)
        .toList();
    expect(states.map((s) => s['overnight_state']).toSet(),
        containsAll(['ready', 'building', 'missing']));
    expect(states.where((s) => s['showing_prior_overnight'] == true), isNotEmpty);
    expect(states.where((s) => s['recovery_day'] != null), isNotEmpty);
    expect(states.where((s) => s['activity_state'] == 'ready'), isNotEmpty);
  });
}
