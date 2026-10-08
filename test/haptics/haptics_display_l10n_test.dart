// The haptics display overhaul adds user-facing strings. Each one lives in the
// template (app_en.arb, with a description and its placeholders) and in EVERY
// other lib/l10n/app_*.arb, including zh, with the same placeholders, so no
// locale falls back to a hard-coded English literal.
//
// Keys pinned (names are the contract the screen reads them by):
//   hapticsPresetsGeneral     "General"            Patterns tab, the ten presets
//   hapticsNewFromTaps        "New from taps"      pinned create row
//   hapticsNewFromNotes       "New from notes"
//   hapticsCommandsCount      plural n             "1 command" / "n commands"
//   hapticsRowSemantics       name, length, commands   a pattern row's label
//   hapticScoreLength         value                "~{value}s" on the staff
//   hapticsCommandLimitTitle  (none)               Band > Safety control title
//   hapticsCommandLimitBody   n                    "n commands in any 2 minutes ..."

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _keys = [
  'hapticsPresetsGeneral',
  'hapticsNewFromTaps',
  'hapticsNewFromNotes',
  'hapticsCommandsCount',
  'hapticsRowSemantics',
  'hapticScoreLength',
  'hapticsCommandLimitTitle',
  'hapticsCommandLimitBody',
];

Map<String, dynamic> _arb(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

void main() {
  final files = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'app_[a-z]+\.arb$').hasMatch(f.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final en = _arb(File('lib/l10n/app_en.arb'));

  test('the glob really covers every locale, zh included', () {
    final names = [for (final f in files) f.uri.pathSegments.last];
    expect(names, containsAll(
        ['app_de.arb', 'app_en.arb', 'app_es.arb', 'app_fr.arb', 'app_hi.arb', 'app_zh.arb']));
  });

  for (final key in _keys) {
    group(key, () {
      test('the template has it, described', () {
        expect(en[key], isA<String>(), reason: 'app_en.arb: $key');
        expect((en[key] as String).trim(), isNotEmpty);
        final meta = en['@$key'];
        expect(meta, isA<Map>(), reason: '@$key');
        expect((meta as Map)['description'], isA<String>());
      });

      for (final f in files) {
        test('${f.uri.pathSegments.last} has it, with its placeholders', () {
          final arb = _arb(f);
          expect(arb[key], isA<String>(), reason: '${f.path}: $key missing');
          final text = arb[key] as String;
          expect(text.trim(), isNotEmpty);
          final meta = en['@$key'];
          final placeholders = meta is Map && meta['placeholders'] is Map
              ? (meta['placeholders'] as Map).keys.cast<String>()
              : const <String>[];
          for (final p in placeholders) {
            expect(text, contains('{$p'),
                reason: '${f.path}: $key must keep the {$p} placeholder');
          }
        });
      }
    });
  }

  test('the English wording the screens rely on', () {
    expect(en['hapticsPresetsGeneral'], 'General');
    expect(en['hapticsNewFromTaps'], 'New from taps');
    expect(en['hapticsNewFromNotes'], 'New from notes');
    expect(en['hapticScoreLength'], '~{value}s');
    expect(en['hapticsCommandsCount'], contains('1 command'));
    expect(en['hapticsCommandsCount'], contains('{n} commands'));
  });
}
