// Phase 4 red: the source catalog card model (contract 8).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/ui2/profile/devices.dart'
    show HealthSource, bandLabelFor;
import 'support/sources_support.dart';

void main() {
  useSourcesDb('sources_catalog_card_test.db');

  final t0 = sec(2026, 9, 1, 0), t6 = sec(2026, 9, 1, 6);
  final seen = DateTime(2026, 9, 29, 8, 30);
  final band = HealthSource(
    name: kBand.name,
    kind: kBand.kind,
    tier: kBand.tier,
    icon: kBand.icon,
    isBand: true,
    family: 'gen4',
    lastData: seen,
  );

  test('a card carries every catalog field for a paired sensor', () async {
    await insertDeviceRow(kStrapA, kRemoteA, 'Polar H10');
    await insertCoverage(kStrapA, InputSignal.rrIntervals, t0, t6);
    final cards = await cardsOf(openService(sources: [band, strap(kStrapA)]));
    final c = cardFor(cards, kStrapA);

    expect(c['name'], 'Polar H10', reason: 'human name');
    expect(c['type'], 'sensor');
    expect(c['model'], bandLabelFor('ble_hrs'),
        reason: 'model comes from the adapter registry, never asserted');
    expect(c['platformIdSuffix'], isNotNull);
    expect(c['identitySuffix'], isNotNull);
    expect(c['signals'], ['hrSparse', 'rrIntervals'],
        reason: 'InputSignal names the adapter declares, sorted');
    expect(c['collection'], 'user-started',
        reason: 'a paired chest strap is armed by a workout and only by one');
    expect(c['coverage'], {
      'rrIntervals': {'start': t0, 'end': t6},
    }, reason: 'earliest start and latest end per signal from device_coverage');
    expect(c['lastSeen'], isNotNull, reason: 'the device row has last_seen');
    expect(c['permissions'], contains('bluetooth'));
    expect((c['limitations'] as List).join(' ').toLowerCase(),
        contains('experimental'),
        reason: 'HealthSource.experimental must reach the card');
  });

  test('the primary band is continuous and its last-seen is the source data',
      () async {
    final cards = await cardsOf(openService(sources: [band]));
    final c = cardFor(cards, kPrimary);
    expect(c['type'], 'band');
    expect(c['collection'], 'continuous');
    expect(c['model'], bandLabelFor('gen4'));
    expect(c['lastSeen'], seen.millisecondsSinceEpoch ~/ 1000,
        reason: 'no device row: HealthSource.lastData, as epoch seconds');
    expect(c['signals'], containsAll(['hr1Hz', 'rrIntervals']));
    expect(c['permissions'], contains('bluetooth'));
    expect((c['limitations'] as List).join(' ').toLowerCase(),
        isNot(contains('experimental')),
        reason: 'gen4 is owner-confirmed');
  });

  test('absent fields are null or empty, never fabricated', () async {
    final cards = await cardsOf(openService(sources: [kPhone]));
    final c = cards.single;
    expect(c['type'], 'phone');
    expect(c['deviceId'], isNull, reason: 'the phone has no device row');
    for (final key in ['model', 'platformIdSuffix', 'identitySuffix', 'coverage', 'lastSeen']) {
      expect(c[key], isNull, reason: '$key is unknown for the phone');
    }
    expect(c['permissions'], isNot(contains('bluetooth')));
    expect((c['supplies'] as List).map((e) => '$e'.toLowerCase()), contains('steps'),
        reason: 'the phone supplies steps, which is not an InputSignal');
    expect(c['signals'], isEmpty);
    expect(c['uses'], isEmpty);
    // No placeholder strings standing in for absence.
    void walk(Object? v) {
      if (v is Map) v.values.forEach(walk);
      if (v is List) v.forEach(walk);
      if (v is String) {
        expect(v.trim(), isNotEmpty);
        expect(v.toLowerCase(), isNot(anyOf('null', 'unknown', 'n/a', 'none')));
      }
    }
    walk(c);
    expect(jsonEncode(c), isNot(contains('"null"')));
  });

  test('a card says which signals use it and why', () async {
    await insertDeviceRow(kStrapA, kRemoteA, 'Polar H10');
    await LocalDb.setSignalPriority(InputSignal.rrIntervals, [kStrapA, kPrimary]);
    await insertCoverage(kStrapA, InputSignal.rrIntervals, t0, t6);
    await insertCoverage(kPrimary, InputSignal.rrIntervals, t0, t6);
    final cards = await cardsOf(openService(sources: [band, strap(kStrapA)]));
    Map<String, Map<String, Object?>> uses(Map<String, Object?> c) => {
      for (final u in c['uses'] as List)
        (u as Map)['signal'] as String: Map<String, Object?>.from(u),
    };
    final strapUses = uses(cardFor(cards, kStrapA));
    final bandUses = uses(cardFor(cards, kPrimary));

    expect(strapUses.keys, contains('rrIntervals'));
    expect(strapUses['rrIntervals']!['reasonCode'], 'userPriority');
    expect((strapUses['rrIntervals']!['reason'] as String).trim(), isNotEmpty);
    expect(bandUses.keys, isNot(contains('rrIntervals')),
        reason: 'the band lost rrIntervals to the strap, so it does not use it');
    expect(bandUses.keys, contains('hr1Hz'));
    expect(bandUses['hr1Hz']!['reasonCode'], 'onlySource',
        reason: 'the band is the only declarer of hr1Hz here');
  });
}
