// Design 06 phase 1c: a derive reads exactly the inputs its groups declare.
//
// A real engine derive of one wearable day (the same setup as
// test/groups/group_key_ownership_test.dart) runs inside
// an `InputReads.begin()` recording. The input ids the tracked `LocalDb` accessors noted must
// equal the union of the declared inputs of the groups that own a key in the
// stored bundle or in `metric_series`:
//   * a read nobody declared fails (a group would not recompute when it moves);
//   * a declared input never read fails, unless it is in
//     [kConditionalInputReads] with the condition this fixture does not meet.
//     That list is a shrink-only ratchet (test/guards/support/ratchets.dart).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/groups/edge_groups.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/input_catalogue.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/input_read_tracker.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/synthetic_day.dart';

/// Declared inputs the fixture derive does not read, with the condition under
/// which a derive does. Shrink-only ratchet `input_reads_conditional`.
const Map<String, String> kConditionalInputReads = <String, String>{
  'vendor_sleep_epoch': 'only when a vendor/wearable hypnogram exists for the '
      'night; the colmi fixture stages from 1 Hz',
  'session_score_mask': 'only when the user masked a session from scoring',
  'step_calibration_day': 'only when a day carries a reference-step row',
  'cycle_log': 'only when the user logs a cycle',
  'cycle_symptom': 'only when the user logs cycle symptoms',
  'journal': 'only when a journal day exists for the derived day',
  'policy': 'calc policies change timing only, never a derive input; kept so '
      'a policy change is stamped (design 06 1c, inventory row)',
};

/// Runs [work] inside one input-read recording and returns the ids noted.
Future<Set<String>> _recorded(Future<void> Function() work) async {
  final rec = InputReads.begin();
  await runZoned(work, zoneValues: rec.zoneValues);
  return rec.end();
}

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const String _id = 'colmi-reads';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

Set<String> _read = {};
final Set<String> _bundleKeys = {};
final Set<String> _seriesKeys = {};
final Set<String> _nestedKeys = {};

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'input_read_tracking_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _id, adapterId: 'colmi', remoteId: 'AA:BB:CC:00:00:0A', label: _id);
    await ColmiLink.instance.ingestForTest(
        _id,
        (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
            ? [colmiBigDataRequest(kColmiBigSleep, [0])]
            : SyntheticDay.colmiRingReply(_days, w, _now),
        nowSeconds: () => SyntheticDay.sec(_now));
    await LocalDb.setCursor(kActiveWearableCursor, _id);
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');

    _read = await _recorded(() async {
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    });

    final row = (await LocalDb.dayResult(_dayId))!;
    final stored = jsonDecode(row['payload_json'] as String) as Map;
    _bundleKeys.addAll(stored.keys.cast());
    for (final b in kMixedBlocks) {
      final v = stored[b];
      if (v is Map) _nestedKeys.addAll(v.keys.map((k) => '$b.$k'));
    }
    final db = await LocalDb.instance;
    for (final r in await db.query('metric_series', columns: ['key'])) {
      _seriesKeys.add(r['key'] as String);
    }
  });

  tearDownAll(() async {
    onWearableDaysChanged = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  /// Groups owning a key the derive wrote.
  Set<String> producedGroups() => {
        for (final k in _bundleKeys) kBundleKeyOwner[k] ?? '?',
        for (final k in _nestedKeys) kNestedKeyOwner[k] ?? '?',
        for (final k in _seriesKeys) kSeriesKeyOwner[k] ?? '?',
      }..remove('?');

  Set<String> expectedInputs() {
    final byId = {for (final g in kMergedRegistry.groups) g.id: g};
    return {
      for (final id in producedGroups())
        for (final i in declaredInputs(byId[id]!)) i.id
    };
  }

  group('the recorder', () {
    test('notes inside a recording are collected, as ids', () async {
      final ids = await _recorded(() async {
        InputReads.note('journal', '2026-10-04');
        await Future<void>.delayed(Duration.zero);
        InputReads.note('decoded', '');
      });
      expect(ids, {'journal', 'decoded'});
    });

    test('note outside a recording is a no-op and nested recordings are '
        'separate', () async {
      InputReads.note('journal', 'x'); // must not throw
      Set<String>? inner;
      final outer = await _recorded(() async {
        InputReads.note('sessions', 'a');
        inner = await _recorded(() async {
          InputReads.note('events', 'b');
        });
      });
      expect(inner, {'events'});
      expect(outer, {'sessions'});
    });
  });

  group('a real one-day derive', () {
    test('the fixture is not vacuous', () {
      expect(_bundleKeys, isNotEmpty);
      expect(producedGroups(), isNotEmpty);
      expect(expectedInputs(), isNotEmpty,
          reason: 'no produced group declares an input');
      expect(_read, isNotEmpty, reason: 'the derive noted no input read');
    });

    test('every input read is declared by a group that produced a key', () {
      final undeclared = _read.difference(expectedInputs());
      expect(undeclared, isEmpty,
          reason: 'read but not declared: ${undeclared.toList()..sort()}');
    });

    test('every declared input is read, or listed as conditional', () {
      final unread =
          expectedInputs().difference(_read).difference(kConditionalInputReads.keys.toSet());
      expect(unread, isEmpty,
          reason: 'declared but never read: ${unread.toList()..sort()}');
    });

    test('the conditional list names only declared, unread inputs', () {
      final exp = expectedInputs();
      for (final e in kConditionalInputReads.entries) {
        expect(e.value.trim(), isNotEmpty, reason: e.key);
        expect(exp.contains(e.key), isTrue,
            reason: '${e.key}: no produced group declares it');
        expect(_read.contains(e.key), isFalse,
            reason: '${e.key}: read by this derive, so not conditional');
      }
    });
  });
}
