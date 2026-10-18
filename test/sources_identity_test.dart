// Stable identity for same-model devices (contract 1).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'support/sources_support.dart';

String _norm(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();

void main() {
  useSourcesDb('sources_identity_test.db');

  Future<void> pairTwo({String a = kStrapA, String b = kStrapB}) async {
    await insertDeviceRow(a, kRemoteA, 'Polar H10');
    await insertDeviceRow(b, kRemoteB, 'Polar H10');
  }

  test('two devices of the same model get distinct short identities', () async {
    await pairTwo();
    final svc = openService(sources: [strap(kStrapA), strap(kStrapB)]);
    final cards = await cardsOf(svc);
    final a = cardFor(cards, kStrapA), b = cardFor(cards, kStrapB);

    expect(a['name'], b['name'], reason: 'fixture: same human name and model');
    final sa = a['identitySuffix'] as String?, sb = b['identitySuffix'] as String?;
    expect(sa, isNotNull, reason: 'a minted device id always yields a suffix');
    expect(sb, isNotNull);
    expect(sa, isNot(sb), reason: 'identity suffixes tell the devices apart');
    for (final c in [a, b]) {
      final s = c['identitySuffix'] as String;
      expect(s.length, inInclusiveRange(4, 6), reason: 'short suffix');
      expect((c['deviceId'] as String).toLowerCase(), endsWith(s.toLowerCase()),
          reason: 'the suffix is a tail of the stable minted id');
      expect(s.toLowerCase(), isNot((c['deviceId'] as String).toLowerCase()),
          reason: 'never the whole id');
    }
    expect(a['displayLabel'], isNot(b['displayLabel']));
    expect(a['displayLabel'], contains(sa!));
    expect(a['displayLabel'], contains(a['name'] as String));
  });

  test('the platform identifier is never shown in full', () async {
    await pairTwo();
    final svc = openService(sources: [strap(kStrapA), strap(kStrapB)]);
    final cards = await cardsOf(svc);
    for (final c in cards) {
      final blob = jsonEncode(c);
      for (final remote in [kRemoteA, kRemoteB]) {
        expect(blob, isNot(contains(remote)));
        expect(_norm(blob), isNot(contains(_norm(remote))),
            reason: 'also not with separators removed');
      }
      final suffix = c['platformIdSuffix'] as String?;
      expect(suffix, isNotNull, reason: 'the device row carries a remote id');
      expect(suffix!.length, lessThanOrEqualTo(4));
      final remote = c['deviceId'] == kStrapA ? kRemoteA : kRemoteB;
      expect(_norm(remote), endsWith(_norm(suffix)),
          reason: 'platform suffix is a tail of the platform id');
      expect(c['displayLabel'], isNot(contains(remote)));
      expect(c['displayLabel'], isNot(contains(c['deviceId'] as String)),
          reason: 'the label shows the suffix, not the full minted id');
    }
  });

  test('ids sharing a tail still get distinct suffixes', () async {
    const x = 'ble_hrs-aaaa1111', y = 'ble_hrs-bbbb1111';
    await pairTwo(a: x, b: y);
    final svc = openService(sources: [strap(x), strap(y)]);
    final cards = await cardsOf(svc);
    final sx = cardFor(cards, x)['identitySuffix'] as String;
    final sy = cardFor(cards, y)['identitySuffix'] as String;
    expect(sx, isNot(sy), reason: 'a shared four-character tail is extended');
    expect(sx.length, lessThanOrEqualTo(6));
    expect(sy.length, lessThanOrEqualTo(6));
  });

  test('identity does not depend on source order or repeat reads', () async {
    await pairTwo();
    final one = await cardsOf(openService(sources: [strap(kStrapA), strap(kStrapB)]));
    final two = await cardsOf(openService(sources: [strap(kStrapB), strap(kStrapA)]));
    for (final id in [kStrapA, kStrapB]) {
      expect(cardFor(two, id)['identitySuffix'], cardFor(one, id)['identitySuffix']);
      expect(cardFor(two, id)['displayLabel'], cardFor(one, id)['displayLabel']);
    }
  });
}
