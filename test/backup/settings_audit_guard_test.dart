// Guard: every place the app keeps state is either carried by a full export or
// listed as not carried, with a reason. A new file root, secure-storage owner
// or native store fails here until someone decides which it is. Same shape as
// kPrefsNotBackedUp.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/backup_extras.dart';

Iterable<File> _dart(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

Iterable<File> _src(String root, List<String> ext) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => ext.any(f.path.endsWith));

void main() {
  final lib = [for (final f in _dart('lib')) f];

  test('every folder root the app writes to is carried or has a reason', () {
    final rx = RegExp(r'getApplicationDocumentsDirectory|'
        r'getApplicationSupportDirectory|getExternalStorageDirectory|'
        r'getDatabasesPath');
    final users = {
      for (final f in lib)
        if (rx.hasMatch(f.readAsStringSync())) f.path,
    };
    final known = {...kFileRootsBackedUp.keys, ...kFileRootsNotBackedUp.keys};
    expect(users.difference(known), isEmpty,
        reason: 'new folder root: carry it (backup_extras.dart) or list it '
            'in kFileRootsNotBackedUp with a reason');
    expect(kFileRootsBackedUp.keys.toSet().intersection(
        kFileRootsNotBackedUp.keys.toSet()), isEmpty);
    expect(known.difference(users), isEmpty, reason: 'stale entry');
    for (final v in [...kFileRootsBackedUp.values, ...kFileRootsNotBackedUp.values]) {
      expect(v, isNotEmpty);
    }
  });

  test('every secure-storage owner is listed with why it is not carried', () {
    final users = {
      for (final f in lib)
        if (f.path != 'lib/data/backup_extras.dart' &&
            f.readAsStringSync().contains('FlutterSecureStorage'))
          f.path,
    };
    expect(users, kSecretsNotBackedUp.keys.toSet(),
        reason: 'a new secret store must be listed in kSecretsNotBackedUp');
    for (final v in kSecretsNotBackedUp.values) {
      expect(v, isNotEmpty);
    }
  });

  test('a credential never sits in plain preferences', () {
    // The key itself lives in secure storage; only a yes/no marker is a pref.
    final rx = RegExp(
        r"""['"]([a-z0-9_.]*(api_key|secret|password|auth_token)[a-z0-9_.]*)['"]""");
    final bad = <String>{};
    for (final f in lib) {
      if (f.path == 'lib/data/backup_extras.dart') continue;
      final t = f.readAsStringSync();
      if (!RegExp(r'\.(setString|setStringList)\(|Prefs\.setString')
          .hasMatch(t)) {
        continue;
      }
      for (final m in rx.allMatches(t)) {
        final k = m.group(1)!;
        if (k.endsWith('_present') || k == 'coach_api_key') continue;
        bad.add('${f.path}: $k');
      }
    }
    expect(bad, isEmpty);
  });

  test('every device-only preference key is real, and listed with a reason', () {
    final all = lib.map((f) => f.readAsStringSync()).join('\n');
    for (final e in kPrefsNotBackedUp.entries) {
      expect(e.value.length, greaterThan(10), reason: e.key);
      // One mention is the denylist entry itself.
      expect("'${e.key}'".allMatches(all).length, greaterThan(1),
          reason: '${e.key} is no longer written anywhere: drop the entry');
      expect(prefsKeyBackedUp(e.key), isFalse);
    }
    for (final k in kPrefsSignalOnly) {
      expect(prefsKeyBackedUp(k), isFalse);
    }
  });

  test('settings that must travel are not shadowed by the denylist', () {
    for (final k in const [
      'backup.cadence',
      'coach_base_url',
      'coach_model',
      'gesture_double_tap_actions',
      'haptic_patterns_v1',
      'notif_alert_rules_v1',
      'theme_choice',
      'alarm_epoch',
    ]) {
      expect(prefsKeyBackedUp(k), isTrue, reason: k);
    }
  });

  test('every native Android store is carried or has a reason', () {
    final rx = RegExp(r'getSharedPreferences\(\s*"([A-Za-z_]+)"');
    final found = <String>{};
    for (final f in _src('android/app/src', ['.kt', '.java'])) {
      for (final m in rx.allMatches(f.readAsStringSync())) {
        found.add(m.group(1)!);
      }
    }
    // PhoneStepCounter names its store through a constant.
    final steps = File(
            'android/app/src/main/kotlin/wtf/openstrap/openstrap_edge/PhoneStepCounter.kt')
        .readAsStringSync();
    final c = RegExp(r'PREFS = "([A-Za-z_]+)"').firstMatch(steps);
    if (c != null) found.add(c.group(1)!);
    expect(found.difference(kNativeStateNotBackedUp.keys.toSet()), isEmpty,
        reason: 'new native store: list it in kNativeStateNotBackedUp');
    for (final v in kNativeStateNotBackedUp.values) {
      expect(v, isNotEmpty);
    }
  });
}
