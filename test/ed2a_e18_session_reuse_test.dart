@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

Future<void> _light(DerivationEngine e) async {
  expect(await e.run(edProfile), greaterThan(0), reason: 'light pass must reach the real derive');
  expect(e.snapshot()['last_error'], isNull);
}

Future<void> _sessionEdit(Map<String, Object?> patch) async {
  await (await LocalDb.instance).update('sessions', patch,
      where: 'id = ?', whereArgs: ['s1']);
}

void main() {
  setUpAll(edInit);
  setUp(() async {
    await edFresh('ed2a_e18.db');
    await edRows(edStart, edStart + 1200);
    await edSession();
  });
  tearDown(edDrop);

  test('finished session ceiling is scanned once across unchanged light passes', () async {
    final e = DerivationEngine();
    await _light(e);
    expect(e.debugCeilingComputed, 1);
    final payload = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(payload['scalars']['hr_ceiling_bpm'], 170,
        reason: 'motion fixture must contain a real held ceiling');
    final first = await edStored(edDay);
    await _light(e);
    expect(await edStored(edDay), first);
    expect(e.debugCeilingComputed, 1, reason: 'a hit must bypass sessionHrCeiling');
  });

  final edits = <String, Future<void> Function(DerivationEngine)>{
    'decoded sample revision (identical REPLACE)': (_) => edRows(edStart + 30, edStart + 31),
    'decoded sample revision (changed HR)': (_) => edRows(edStart + 30, edStart + 300, hr: 160),
    'late RR input revision': (_) async {
      final t = edStart + 30;
      await (await LocalDb.instance).insert('decoded_rr', {'device_id': '',
        'ts_ms': t * 1000, 'rec_ts': t, 'rr_ts_ms': t * 1000, 'beat_index': 0, 'rr_ms': 900});
    },
    'session revision (identical REPLACE)': (_) => edSession(),
    'session revision (identical UPDATE)': (_) => _sessionEdit({'type': 'run'}),
    'session identity': (_) => _sessionEdit({'id': 's2'}),
    'session type': (_) => _sessionEdit({'type': 'bike'}),
    'session start': (_) => _sessionEdit({'start_ts': edStart + 1}),
    'session end': (_) => _sessionEdit({'end_ts': edStart + 1000}),
    'clipped sample window': (_) async {
      await (await LocalDb.instance).delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [edStart + 10]);
    },
    'family': (_) async { await (await LocalDb.instance).update(
        'decoded_onehz', {'device_family': 'gen5'}); },
    'HR ownership': (_) async {
      // The primary needs coverage too: as the only covering candidate,
      // `other` would own the whole window and leave the day without HR.
      await (await LocalDb.instance).insert('device_coverage', {'device_id': '',
        'signal': 'hr1Hz', 'start_ts': edStart, 'end_ts': edStart + 1200});
      await edOwnership(signals: ['hr1Hz']);
    },
    'accel ownership': (_) async {
      final db = await LocalDb.instance;
      await db.insert('device_coverage', {'device_id': 'other', 'signal': 'accel1Hz',
        'start_ts': edStart, 'end_ts': edStart + 600});
      await db.insert('signal_priority', {'device_id': 'other', 'signal': 'accel1Hz',
        'rank': 0, 'user_set': 1});
    },
    'priority without changed input revisions': (_) async {
      await (await LocalDb.instance).insert('signal_priority', {'signal': 'hr1Hz',
        'device_id': '', 'rank': 2, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    },
    'store generation': (_) async { await LocalDb.close(); await LocalDb.instance; },
    'algorithm': (e) async { e.debugSessionCacheRekey(kAlgoVersion - 1); },
  };
  for (final edit in edits.entries) {
    test('${edit.key}: miss, exact result, then reuse new key', () async {
      if (edit.key.startsWith('priority ')) await edPriorityOrder(['', 'other']);
      final e = DerivationEngine();
      await _light(e);
      final count = e.debugCeilingComputed;
      expect(count, 1);
      await edit.value(e);
      await _light(e);
      expect(e.debugCeilingComputed, count + 1, reason: 'changed ${edit.key} must rescan');
      final warm = await edStored(edDay);
      final cold = DerivationEngine()..debugDisableSessionReuse = true;
      expect(await cold.runDays(edProfile, {edDay}), 1);
      expect(await edStored(edDay), warm,
          reason: 'includes the full metric envelope and unrounded winning session');
      final after = e.debugCeilingComputed;
      await _light(e);
      expect(e.debugCeilingComputed, after, reason: 'new key should now hit');
    });
  }

  test('an absent ceiling is reusable without inventing a number', () async {
    await edRows(edStart, edStart + 1200, az: 1);
    final e = DerivationEngine();
    await _light(e);
    final first = await edStored(edDay);
    final payload = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(payload['hr_ceiling']['value'], '—');
    expect(payload['scalars']['hr_ceiling_bpm'], isNull);
    await _light(e);
    expect(await edStored(edDay), first);
    expect(e.debugCeilingComputed, 1, reason: 'absence is a cached result too');
  });

  test('live sessions always recompute, including done to live transition (guard)', () async {
    final e = DerivationEngine();
    await _light(e);
    await _sessionEdit({'status': 'live'});
    final before = e.debugCeilingComputed;
    await _light(e);
    expect(e.debugCeilingComputed, before + 1);
    await _light(e);
    expect(e.debugCeilingComputed, before + 2);
    await _sessionEdit({'status': 'done'});
    await _light(e);
    expect(e.debugCeilingComputed, before + 3, reason: 'return to done must not resurrect stale entry');
  });

  for (final mode in ['heavy', 'force', 'selected']) {
    test('$mode pass always recomputes (guard)', () async {
      final e = DerivationEngine();
      await _light(e);
      final count = e.debugCeilingComputed;
      final done = switch (mode) {
        'heavy' => await e.run(edProfile, heavy: true),
        'force' => await e.run(edProfile, force: true),
        _ => await e.runDays(edProfile, {edDay}),
      };
      expect(done, greaterThan(0));
      expect(e.debugCeilingComputed, greaterThan(count));
    });
  }

  test('session removal does not keep its former ceiling (guard)', () async {
    final e = DerivationEngine();
    await _light(e);
    await (await LocalDb.instance).delete('sessions', where: 'id = ?', whereArgs: ['s1']);
    await _light(e);
    final got = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(got['hr_ceiling']['value'], '—');
    expect(got['scalars']['hr_ceiling_bpm'], isNull);
  });

  test('existing fixture: reuse and forced output byte equality after invalidation (guard)', () async {
    await edExistingFixture();
    final e = DerivationEngine();
    final cold = DerivationEngine()..debugDisableSessionReuse = true;
    await _light(e);
    await _light(e);
    final before = await edStored(edDay);
    await cold.runDays(edProfile, {edDay});
    expect(await edStored(edDay), before);
    await edRows(edStart + 30, edStart + 300, hr: 160);
    await _light(e);
    final changed = await edStored(edDay);
    await cold.runDays(edProfile, {edDay});
    expect(await edStored(edDay), changed);
  });
}
