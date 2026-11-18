// What a candidate official file must satisfy (spec §4.3, §6.2; P1 red:
// "baseline candidate payload fails empty-results/checkpoint requirements").
//
// WHY: a copy of the fork's rows into the target layout looks plausible and the
// receiver accepts it, yet it would serve fork scores as official results and
// feed a fork checkpoint to the target's night reader. The requirements checker
// must reject that baseline and accept a correct payload.
// CLAIM(official-export-no-fork-results), CLAIM(official-export-checkpoint-domain).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';

import 'candidate_stub.dart';
import 'rich_fixture.dart';
import 'support.dart';

String _kinds(List<PayloadViolation> v) => (v.map((x) => x.kind).toSet().toList()..sort()).join(',');

void main() {
  late RichFixture fx;
  // Each candidate build creates ~80 tables and their triggers: seconds, not ms.
  const slow = Timeout(Duration(minutes: 3));
  setUpAll(() async => fx = await RichFixture.build());
  tearDownAll(() => fx.dispose());

  test('the naive copy of the fork file into the target layout is rejected',
      () async {
    final inv = await fx.inventoryOf(await naiveCopyCandidate(fx));
    final v = checkPayload(
      inv,
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(v.map((x) => x.text), containsAll([
      'day_result', // fork results at several versions incl. algorithm 124
      'day_checkpoint', // a fork DAY-format checkpoint in the target domain
      'sync_cursor:band_cursor', // a hardware cursor
      'compute_freshness:day_algo', // a non-archive freshness key
    ]));
    expect(_kinds(v), contains('droppedTableHasRows'));
    expect(_kinds(v), contains('foreignCursor'));
    expect(_kinds(v), contains('foreignFreshnessKey'));
  }, timeout: slow);

  test('the naive copy carries the fork cursor, not the recomputed edge',
      () async {
    final inv = await fx.inventoryOf(await naiveCopyCandidate(fx));
    final v = checkPayload(
      inv,
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(v.where((x) => x.kind == 'prunedBeforeMismatch'), hasLength(1));
  }, timeout: slow);

  test('a payload that follows the policy has no violation', () async {
    final inv = await fx.inventoryOf(await policyCandidate(fx));
    expect(
      checkPayload(
        inv,
        officialProfile,
        target: loadCapture('target_schema_62.json'),
        expectedPrunedBefore: fx.expectedPrunedBefore,
      ),
      isEmpty,
    );
  }, timeout: slow);

  test('wrong schema version and a table the target does not have are caught',
      () async {
    final path = await policyCandidate(fx, userVersion: 58, extraTable: true);
    final v = checkPayload(
      await fx.inventoryOf(path),
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(_kinds(v), allOf(contains('userVersion'), contains('unknownTable')));
  }, timeout: slow);

  test('a day_result without the `imported` column is a layout violation',
      () async {
    final v = checkPayload(
      await fx.inventoryOf(await policyCandidate(fx, dropImported: true)),
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(_kinds(v), contains('layout'));
  }, timeout: slow);
}
