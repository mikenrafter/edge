import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/wake/wake_night_context_db.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late TracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_natural_t2.db');
    store = TracksStore(await LocalDb.instance);
    for (final id in ['tea ritual', 'reading']) {
      await store.saveDefinition(TrackDefinition(
        id: id, name: id, icon: 'track', kind: 'activity',
        roles: ['own_sleep'], systems: ['sleep'],
      ));
    }
  });
  tearDown(() => env.dispose());
  Future<void> log(String id, DateTime at) => store.log(TrackEvent(
    id: '$id:${at.millisecondsSinceEpoch}', trackId: id,
    date: dayLabelOf(at), atMs: at.millisecondsSinceEpoch,
  ));
  Future<ConfounderProfile> profile(DateTime bed) =>
    const DbWakeNightSource().profile(
      DateTime(bed.year, bed.month, bed.day),
      DateTime(bed.year, bed.month, bed.day + 1), bed,
    );

  test('own-sleep user identities compose without inventing thresholds', () async {
    final bed = DateTime(2026, 9, 1, 22);
    await log('tea ritual', bed.subtract(const Duration(hours: 6)));
    final a = await profile(bed);
    expect(a, isNot(ConfounderProfile.identity));
    expect(a.hrArousalBpm, 4);
    expect(a.combine(ConfounderProfile.identity), a);
    await log('reading', bed.subtract(const Duration(hours: 1)));
    final ab = await profile(bed);
    final bed2 = DateTime(2026, 9, 2, 22);
    await log('reading', bed2.subtract(const Duration(hours: 1)));
    final b = await profile(bed2);
    expect(a, isNot(b));
    expect(a.combine(b), ab);
    expect(a.combine(b), b.combine(a));
    expect(a.combine(b).combine(a), a.combine(b.combine(a)));
  });

  test('definition and event edits invalidate the occurrence cache revision', () async {
    const source = DbWakeNightSource();
    final from = DateTime(2026, 9, 1), to = DateTime(2026, 9, 2);
    final before = await source.revision(from, to);
    await log('reading', DateTime(2026, 9, 1, 21));
    final logged = await source.revision(from, to);
    expect(logged, isNot(before));
    final d = (await store.definitions()).firstWhere((d) => d.id == 'reading');
    await store.saveDefinition(TrackDefinition.fromJson({...d.toJson(), 'roles': []}));
    expect(await source.revision(from, to), isNot(logged));
  });

  test('future, disabled and non-sleep tracks cannot affect tonight', () async {
    final bed = DateTime(2026, 9, 1, 22);
    await log('reading', bed.add(const Duration(minutes: 1)));
    expect(await profile(bed), ConfounderProfile.identity);
    await log('tea ritual', bed.subtract(const Duration(hours: 1)));
    await store.deleteDefinition('tea ritual');
    expect(await profile(bed), ConfounderProfile.identity);
    final d = (await store.definitions()).firstWhere((d) => d.id == 'reading');
    await store.saveDefinition(TrackDefinition.fromJson({...d.toJson(), 'systems': ['glucose']}));
    await log('reading', bed.subtract(const Duration(hours: 1)));
    expect(await profile(bed), ConfounderProfile.identity);
  });

  test('user Natural wake learns independently and persists an explained step', () async {
    final db = await LocalDb.instance;
    const journal = DbWakeJournal();
    for (var i = 0; i < 7; i++) {
      final onset = DateTime(2026, 9, 1 + i * 7, 22);
      final wake = DateTime(2026, 9, 2 + i * 7, 7);
      final epoch = wake.millisecondsSinceEpoch ~/ 1000;
      await log('reading', onset.subtract(const Duration(hours: 1)));
      await db.insert('day_result', {
        'day_id': dayLabelOf(wake), 'algo_version': 118, 'computed_at': 1, 'finalized': 1,
        'window_json': jsonEncode({'onset_ms': onset.millisecondsSinceEpoch, 'offset_ms': wake.millisecondsSinceEpoch}),
        'payload_json': jsonEncode({'scalars': {'readiness': 80}, 'sleep': {'accounting': {'value': {'tst_sec': 28800}}}}),
      });
      await db.insert('wake_trace', {'wake_epoch': epoch, 'at_ms': (epoch - 60) * 1000, 'kind': 'natural', 'data_json': '{"reason":"fire"}'});
      await db.insert('wake_trace', {'wake_epoch': epoch, 'at_ms': epoch * 1000, 'kind': 'ack', 'data_json': jsonEncode({'dreamAnswer': 'dream', 'wakePath': 'natural', 'dreamAnsweredAtMs': epoch * 1000})});
      await journal.tuneFor(epoch);
    }
    await LocalDb.close();
    final meta = await (await LocalDb.instance).query('wake_meta', where: 'key = ?', whereArgs: ['natural_wake_user_reading']);
    expect(meta, hasLength(1));
    final values = jsonDecode(meta.single['value'] as String) as Map;
    expect(values['windowLeadMinutes'], 1);
    final other = await (await LocalDb.instance).query('wake_meta', where: 'key = ?', whereArgs: ['natural_wake_user_tea%20ritual']);
    expect(other, isEmpty);
  });
}
