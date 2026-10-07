import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_store.dart';

import 'outcome_rig.dart';

class Disk {
  final Map<String, String> kv = {};
  int writes = 0;
  WakeOutcomeStore get store => WakeOutcomeStore(
        read: (k) async => kv[k],
        write: (k, v) async {
          writes++;
          kv[k] = v;
        },
      );
}

void main() {
  test('the key and the cap are the documented ones', () {
    expect(kWakeOutcomesKey, 'outcomes_v1');
    expect(kWakeOutcomeCap, 120);
  });

  test('an empty disk loads empty', () async {
    expect(await Disk().store.load(), isEmpty);
  });

  test('round trip: what was upserted loads back, nulls and all', () async {
    final d = Disk();
    final o = outcome(
      kT,
      grogginess: 2,
      stageAtFire: 'awake',
      exclusions: [WakeExclusion.alreadyAwake],
      latencySec: {
        WakeResponseKind.deliberateAck: 95,
        WakeResponseKind.appInteraction: null,
        WakeResponseKind.movement: 20,
      },
    );
    await d.store.upsert(o);
    // A fresh store over the same disk, as after a restart.
    final back = await d.store.load();
    expect(back, hasLength(1));
    expect(back.single.toJson(), o.toJson());
    expect(back.single.latencySec[WakeResponseKind.appInteraction], isNull);
    expect(d.kv.keys, [kWakeOutcomesKey]);
  });

  test('newest first, by wakeSec', () async {
    final d = Disk();
    for (final s in [kT, kT + 2 * 86400, kT + 86400]) {
      await d.store.upsert(outcome(s));
    }
    expect([for (final o in await d.store.load()) o.wakeSec],
        [kT + 2 * 86400, kT + 86400, kT]);
  });

  test('upsert replaces the same wakeSec and never duplicates', () async {
    final d = Disk();
    await d.store.upsert(outcome(kT, grogginess: 5));
    await d.store.upsert(outcome(kT, minutesBeforeT: 45));
    final all = await d.store.load();
    expect(all, hasLength(1));
    expect(all.single.minutesBeforeT, 45.0);
    expect(all.single.grogginess, isNull, reason: 'the caller value replaces');
  });

  test('capped at 120: the newest are kept', () async {
    final d = Disk();
    for (var i = 0; i < 125; i++) {
      await d.store.upsert(outcome(kT + i * 86400));
    }
    final all = await d.store.load();
    expect(all, hasLength(kWakeOutcomeCap));
    expect(all.first.wakeSec, kT + 124 * 86400);
    expect(all.last.wakeSec, kT + 5 * 86400, reason: 'the oldest 5 dropped');
    expect((jsonDecode(d.kv[kWakeOutcomesKey]!) as List), hasLength(120));
  });

  group('rate', () {
    // RED (round 3, P2): rate() rebuilt the outcome field by field and dropped
    // configuredWindowMinutes. Every field is non-null and distinct here, so a
    // dropped or swapped field changes the JSON; the key list guards the test
    // itself against a field added to toJson that this outcome does not set.
    test('rating round-trips EVERY field: only grogginess changes', () async {
      final full = WakeOutcome(
        wakeSec: kT,
        firedBy: WakeFiredBy.natural,
        firedAtSec: kT - 1230,
        stageAtFire: 'awake',
        stageAgeSec: 41,
        delivered: true,
        latencySec: const {
          WakeResponseKind.deliberateAck: 95,
          WakeResponseKind.appInteraction: 130,
          WakeResponseKind.movement: 20,
        },
        grogginess: 2,
        minutesBeforeT: 20.5,
        configuredWindowMinutes: 45,
        exclusions: const [WakeExclusion.staleStage, WakeExclusion.crossedEpisode],
      );
      final before = full.toJson();
      expect(before.keys.toSet(), {
        'wakeSec', 'firedBy', 'firedAtSec', 'stageAtFire', 'stageAgeSec',
        'delivered', 'latencySec', 'grogginess', 'minutesBeforeT',
        'configuredWindowMinutes', 'exclusions',
      }, reason: 'a new field: extend this outcome and this list');
      expect(before.values.where((v) => v == null), isEmpty);

      final d = Disk();
      await d.store.upsert(full);
      await d.store.rate(kT, 5);
      final back = (await d.store.load()).single;
      expect(back.toJson(), {...before, 'grogginess': 5});
      expect(back.configuredWindowMinutes, 45);
    });

    test('sets the rating on the stored outcome only', () async {
      final d = Disk();
      await d.store.upsert(outcome(kT));
      await d.store.upsert(outcome(kT + 86400));
      await d.store.rate(kT, 4);
      final all = await d.store.load();
      expect(all.firstWhere((o) => o.wakeSec == kT).grogginess, 4);
      expect(all.firstWhere((o) => o.wakeSec == kT + 86400).grogginess, isNull);
    });

    test('re-rating replaces', () async {
      final d = Disk();
      await d.store.upsert(outcome(kT, grogginess: 2));
      await d.store.rate(kT, 5);
      expect((await d.store.load()).single.grogginess, 5);
    });

    for (final bad in [0, 6, -1, 100]) {
      test('$bad is out of range', () async {
        final d = Disk();
        await d.store.upsert(outcome(kT));
        final before = d.writes;
        await expectLater(d.store.rate(kT, bad), throwsArgumentError);
        expect(d.writes, before);
        expect((await d.store.load()).single.grogginess, isNull);
      });
    }

    test('out of range throws even for an unknown wake', () async {
      await expectLater(Disk().store.rate(kT, 9), throwsArgumentError);
    });

    test('1 and 5 are accepted', () async {
      final d = Disk();
      await d.store.upsert(outcome(kT));
      await d.store.rate(kT, 1);
      expect((await d.store.load()).single.grogginess, 1);
      await d.store.rate(kT, 5);
      expect((await d.store.load()).single.grogginess, 5);
    });

    test('an unknown wake is a no-op: nothing written', () async {
      final d = Disk();
      await d.store.upsert(outcome(kT));
      final before = d.writes;
      await d.store.rate(kT + 1, 3);
      expect(d.writes, before);
      expect((await d.store.load()).single.grogginess, isNull);
    });
  });

  group('corrupt storage', () {
    for (final raw in ['not json {', '{"a":1}', '42', '', 'null']) {
      test('"$raw" loads empty and does not throw', () async {
        final d = Disk()..kv[kWakeOutcomesKey] = raw;
        expect(await d.store.load(), isEmpty);
      });
    }

    test('a corrupt entry in a valid list is skipped', () async {
      final d = Disk();
      await d.store.upsert(outcome(kT));
      final list = jsonDecode(d.kv[kWakeOutcomesKey]!) as List;
      list.add({'wakeSec': 'garbage'});
      list.add(7);
      d.kv[kWakeOutcomesKey] = jsonEncode(list);
      final all = await d.store.load();
      expect(all.map((o) => o.wakeSec), [kT]);
    });

    test('upsert over corrupt storage starts fresh', () async {
      final d = Disk()..kv[kWakeOutcomesKey] = '<<<';
      await d.store.upsert(outcome(kT));
      expect((await d.store.load()).map((o) => o.wakeSec), [kT]);
    });
  });
}
