// P2.0a review r1 (Sol): the "byte" counters are UTF-8 bytes, measured only
// when somebody reads them; a disabled DerivePerf never runs a measuring walk;
// and the repository's reader wrappers (ReadPerf.reading) cannot be lost
// silently.

@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/last_result_db.dart';

const _db = 'perf_counters_review_test.db';

// 2-byte, 3-byte, 4-byte (surrogate pair) and a lone surrogate (encoded as
// U+FFFD, 3 bytes).
const _samples = ['', 'abc', 'é', '日本', '😀', 'a\u{1F600}é日b', '\uD800x', 'x\uDC00'];

DerivePerf _sink() => DerivePerf(nowMs: () => 0)..startPass();
Map<String, int> _counts(DerivePerf p) =>
    (p.summary()['counts'] as Map).cast<String, int>();

/// Records which counters arrive eagerly and which lazily.
class _SpyPerf extends DerivePerf {
  _SpyPerf({required super.enabled}) : super(nowMs: _zero);
  static int _zero() => 0;
  final eager = <String>[];
  final lazy = <String>[];
  @override
  void addCount(String name, int n) {
    eager.add(name);
    super.addCount(name, n);
  }

  @override
  void addCountLazy(String name, int Function() value) {
    lazy.add(name);
    super.addCountLazy(name, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDown(() => ReadPerf.sink = null);
  tearDownAll(() => g1DropDb(_db));

  group('utf8Length', () {
    test('equals the UTF-8 encoding length, lone surrogates included', () {
      for (final s in _samples) {
        expect(utf8Length(s), utf8.encode(s).length, reason: s.runes.toList().toString());
      }
    });
  });

  group('byte counters are UTF-8 bytes', () {
    const stored = '{"n":"日本é😀"}'; // 14 UTF-16 units, 23 bytes
    test('the fixture really differs between units and bytes', () {
      expect(stored.length, isNot(utf8.encode(stored).length));
    });

    test('rowsByteEstimate counts a String by its UTF-8 length', () {
      expect(
          rowsByteEstimate([
            {'a': stored}
          ]),
          utf8.encode(stored).length);
    });

    test('ReadPerf.payload and .crossday book exact UTF-8 bytes', () {
      final sink = ReadPerf.sink = _sink();
      ReadPerf.payload(stored, {'n': 'x'});
      ReadPerf.crossday(stored, {'n': 'x'});
      final c = _counts(sink);
      expect(c['payload_bytes_other'], utf8.encode(stored).length);
      expect(c['crossday_payload_bytes'], utf8.encode(stored).length);
    });

    test('ReadPerf.lastResult* book exact UTF-8 bytes', () {
      final sink = ReadPerf.sink = _sink();
      ReadPerf.lastResultPut('beats|d', stored);
      ReadPerf.lastResultRead('beats|d', stored, {'n': 'x'});
      final c = _counts(sink);
      expect(c['last_result_put_bytes_beats'], utf8.encode(stored).length);
      expect(c['last_result_read_bytes_beats'], utf8.encode(stored).length);
    });

    test('LastResultCache put and table read book the encoded UTF-8 size',
        () async {
      await g1FreshDb(_db);
      await LocalDb.instance;
      final value = <String, Object?>{'s': '日本é😀'};
      final bytes = utf8.encode(jsonEncode(value)).length;
      final sink = ReadPerf.sink = _sink();
      final cache = LastResultCache(now: () => DateTime.utc(2025, 9, 2, 12));
      cache.put('beats|d', value);
      await cache.flush();
      await LastResultCache().read<Map>('beats|d');
      final c = _counts(sink);
      expect(c['last_result_put_bytes_beats'], bytes);
      expect(c['last_result_read_bytes_beats'], bytes);
    });

    test('a disabled sink measures nothing (no byte walk)', () {
      final off = ReadPerf.sink = DerivePerf(nowMs: () => 0, enabled: false);
      ReadPerf.payload(stored, {'n': 'x'});
      ReadPerf.crossday(stored, {'n': 'x'});
      ReadPerf.lastResultPut('beats|d', stored);
      ReadPerf.lastResultRead('beats|d', stored, {'n': 'x'});
      expect(off.summary()['counts'], isEmpty);
    });

    test('the byte values reach the sink lazily', () {
      final s = _SpyPerf(enabled: false);
      ReadPerf.sink = s;
      ReadPerf.payload(stored, {'n': 'x'});
      ReadPerf.lastResultPut('beats|d', stored);
      expect(s.eager.where((n) => n.contains('bytes')), isEmpty,
          reason: 'a byte count is computed inside addCountLazy only');
      expect(s.lazy, containsAll(['payload_bytes_other', 'last_result_put_bytes_beats']));
    });
  });

  group('the derive side measures lazily', () {
    final start = DateTime(2025, 9, 2, 8).millisecondsSinceEpoch ~/ 1000;

    Future<void> seed() async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      for (var i = 0; i < 600; i++) {
        final ts = start + i;
        batch.insert('decoded_onehz', {
          'device_id': '',
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'counter': ts,
          'hr': 0,
          'ax': 0.0,
          'ay': 0.0,
          'az': 1.0,
          'device_family': 'gen4',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }

    Future<_SpyPerf> derive(bool enabled) async {
      await g1FreshDb(_db);
      await LocalDb.instance;
      await seed();
      final spy = _SpyPerf(enabled: enabled);
      await DerivationEngine(perf: spy)
          .runDays(const Profile(), {'2025-09-02'}, force: true);
      return spy;
    }

    test('disabled: the cross-day payload size walk is never run', () async {
      final spy = await derive(false);
      expect(spy.lazy, contains('crossday_payload_chars'),
          reason: 'the fold over the stored payloads goes through addCountLazy');
      expect(spy.eager, isNot(contains('crossday_payload_chars')));
      expect(spy.summary()['counts'], isEmpty);
    });

    test('enabled: the same counter is booked', () async {
      final spy = await derive(true);
      expect(_counts(spy), contains('crossday_payload_chars'));
    });
  });

  test('the repository reader wrappers are the pinned set (none lost)', () {
    final src = File('lib/data/local_repository_impl.dart').readAsStringSync();
    final wrapped = [
      for (final m in RegExp(r"ReadPerf\.reading\('(\w+)'").allMatches(src))
        m.group(1)!,
    ];
    expect(wrapped, hasLength(20), reason: wrapped.join(', '));
    expect(wrapped.toSet(), hasLength(20), reason: 'a name wrapped twice');
    expect(
      wrapped.toSet(),
      {
        'getToday', 'getInsights', 'getDayHeart', 'getDayHrv', 'getDaySleep',
        'getDaySleepV2', 'getDayLungs', 'getDayWear', 'getDayNaps',
        'getDaySteps', 'getDayStress', 'getDayStrain', 'getDayOverview',
        'getDayTimeline', 'getChart', 'getJournal', 'getJournalInsights',
        'getCycle', 'getCycleSymptoms', 'getZones',
      },
    );
    // Each wrapper sits on the method it names.
    for (final n in wrapped) {
      expect(
        RegExp("\\b$n\\([^;]*?\\)\\s*=>\\s*ReadPerf\\.reading\\('$n'")
            .hasMatch(src),
        isTrue,
        reason: '$n is wrapped under another method\'s name',
      );
    }
  });
}
