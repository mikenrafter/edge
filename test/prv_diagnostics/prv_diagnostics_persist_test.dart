// PRV diagnostics (design 04 R4 follow-up, item e/f): the evidence behind the
// irregular-rhythm screen is PERSISTED in the day bundle, for the 24 h screen
// and the sleep-window screen, for a screen that ran AND one that abstained;
// the streaming day path stores what the batch path stores; and the change is
// versioned (kAlgoVersion bump + changelog + a new full-SHA analytics pin).
//
// Needs the analytics sibling's `irregularBeatScreenDetailed` /
// `IrregularScreenState.evaluateDetailed` (red stubs in analytics-prv).
//
// What lands where (design question 1 in the report: this layout is the tests'
// choice, not a given):
//   clinical.irregular_24h  envelope + a `diagnostics` key (the analytics wire
//                            shape, IrregularScreenResult.toJson())
//   clinical.irregular      the sleep screen's plain map + `pnn_pct`,
//                            `n_beats`, `sd1_sd2` (were computed, discarded)
//                            + `diagnostics`
//
// Dates are fixed; nothing reads the real clock. Run with TZ=UTC.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_rr_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/compute/sleep_blank.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/day_stream_fixture.dart';
import '../support/incremental_day_fixture.dart';

String _j(Object? o) => jsonEncode(o);

List<double> _d(Object? l) => [for (final v in l as List) (v as num).toDouble()];

Map<String, dynamic> _clinical(Map<String, dynamic> bundle) =>
    (bundle['clinical'] as Map).cast<String, dynamic>();

/// The sleep screen exactly as `deriveDayBundle` computes it, plus the
/// corrector's own counts: the oracle the stored diagnostics must equal.
ana.IrregularScreenResult _refSleep(Map<String, dynamic> input) {
  final rr = _d(input['sleep_rr_ms']), ts = _d(input['sleep_rr_ts_ms']);
  final c = ana.correctRr(rr, rrTsMs: ts);
  return ana.irregularBeatScreenDetailed(
    c.nn,
    nnTimesMs: c.nnTimesMs,
    artifactFraction: (1.0 - c.cleanFraction).clamp(0.0, 1.0),
    cleaning: ana.RrCleaningCounts(
        raw: rr.length, corrected: c.correctedCount, dropped: c.droppedCount),
  );
}

ana.IrregularScreenResult _refDay(List<double> rr, List<double> ts) {
  final c = ana.correctRr(rr, rrTsMs: ts.isEmpty ? null : ts);
  return ana.irregularBeatScreenDetailed(
    c.nn,
    nnTimesMs: c.nnTimesMs,
    artifactFraction: (1.0 - c.cleanFraction).clamp(0.0, 1.0),
    cleaning: ana.RrCleaningCounts(
        raw: rr.length, corrected: c.correctedCount, dropped: c.droppedCount),
  );
}

DayRrState _restart(DayRrState s) {
  final w = ResumeWriter();
  s.write(w);
  final r = ResumeReader(w.takeBytes());
  final back = DayRrState.read(r);
  expect(r.remaining, 0);
  return back;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('deriveDayBundle persists the diagnostics', () {
    test('a night long enough to screen: sleep pNN, beats, corrected/dropped, '
        'windows - and the same for the 24 h screen', () {
      final input = incrementalDay(nightSeconds: 3600, gaps: true);
      final bundle = deriveDayBundle(copyDay(input));
      final clin = _clinical(bundle);

      // Structure first, so a missing key fails as a missing key.
      final sleep = (clin['irregular'] as Map).cast<String, dynamic>();
      expect(sleep['diagnostics'], isA<Map>(),
          reason: 'clinical.irregular carries the sleep screen\'s diagnostics');
      final env24 = (clin['irregular_24h'] as Map).cast<String, dynamic>();
      expect(env24['diagnostics'], isA<Map>(),
          reason: 'clinical.irregular_24h carries the 24 h diagnostics');
      for (final k in ['pnn_pct', 'n_beats', 'sd1_sd2']) {
        expect(sleep[k], isA<num>(),
            reason: 'sleep $k was computed and discarded; now stored');
      }

      // Then the values: the analytics oracle over the same beats.
      final refSleep = _refSleep(input);
      expect(refSleep.metric.present, isTrue, reason: 'fixture: a present screen');
      expect(refSleep.diagnostics.corrected, greaterThan(0),
          reason: 'fixture: the corrector really corrected');
      expect(_j(sleep['diagnostics']), _j(refSleep.diagnostics.toJson()));
      expect(sleep['n_beats'], refSleep.metric.value!.nBeats);
      expect(sleep['pnn_pct'], closeTo(refSleep.metric.value!.pnnPct, 0.06));
      expect(sleep['sd1_sd2'], closeTo(refSleep.metric.value!.sd1sd2, 0.06));
      expect((sleep['diagnostics'] as Map)['beats']['nn_kept'],
          sleep['n_beats'],
          reason: 'one beat count, shown twice');

      final ref24 = _refDay(_d(input['day_rr_ms']), _d(input['day_rr_ts_ms']));
      expect(_j(env24['diagnostics']), _j(ref24.diagnostics.toJson()));
      // Every pre-existing key of the envelope is where it was.
      for (final k in ['value', 'confidence', 'tier', 'inputs_used', 'note']) {
        expect(env24.containsKey(k), isTrue, reason: 'envelope keeps $k');
      }
      expect(_j(env24['value']),
          _j(ref24.metric.toJson((v) => v.toJson())['value']));
    });

    test('a night too thin to screen: the abstention carries its counts, and '
        'no figure is invented', () {
      final input = incrementalDay(); // 361 s of night: ~380 beats < 500
      final bundle = deriveDayBundle(copyDay(input));
      final clin = _clinical(bundle);
      final sleep = (clin['irregular'] as Map).cast<String, dynamic>();
      final diag = sleep['diagnostics'];
      expect(diag, isA<Map>(), reason: 'an abstained screen still explains why');
      final d = (diag as Map).cast<String, dynamic>();
      expect(d['abstain'], 'too_few_beats');
      expect((d['beats'] as Map)['nn_kept'], lessThan(500));
      expect((d['thresholds'] as Map)['min_beats'], 500);
      expect(sleep['sd1'], isNull);
      expect(sleep['pnn_pct'], isNull, reason: 'absent is null, never 0');
      expect(sleep['n_beats'], isNull, reason: 'absent is null, never 0');
      expect(_j(d), _j(_refSleep(input).diagnostics.toJson()));
      final env24 = (clin['irregular_24h'] as Map).cast<String, dynamic>();
      expect(env24['value'], '—');
      expect((env24['diagnostics'] as Map)['abstain'], 'too_few_beats');
    });

    test('a day with no night at all: zero beats, and the cleaning counts the '
        'corrector reports (not a 0 it did not measure)', () {
      final input = incrementalDay(nightSeconds: 3600);
      input
        ..['sleep_rr_ms'] = <double>[]
        ..['sleep_rr_ts_ms'] = <double>[];
      final sleep = (_clinical(deriveDayBundle(copyDay(input)))['irregular']
              as Map)
          .cast<String, dynamic>();
      expect(sleep['diagnostics'], isA<Map>(),
          reason: 'no night: the screen abstains and says so');
      final d = (sleep['diagnostics'] as Map).cast<String, dynamic>();
      expect(d['abstain'], 'too_few_beats');
      expect((d['beats'] as Map)['nn_in'], 0);
      expect((d['beats'] as Map)['nn_kept'], 0);
      expect((d['beats'] as Map)['rr_raw'], 0,
          reason: 'the corrector ran over zero beats: a measured 0');
    });

    test('a blanked night does not keep the stored night\'s diagnostics', () {
      final input = incrementalDay(nightSeconds: 3600);
      final prev = deriveDayBundle(copyDay(input));
      final blankInput = copyDay(input)
        ..['sleep_rr_ms'] = <double>[]
        ..['sleep_rr_ts_ms'] = <double>[];
      final absent = deriveDayBundle(blankInput);
      final absentDiag = (_clinical(absent)['irregular'] as Map)['diagnostics'];
      expect(absentDiag, isA<Map>(), reason: 'the engine\'s own absent envelope');
      final blanked = blankNightInBundle(prev, absent, source: 'user');
      expect(_j((_clinical(blanked)['irregular'] as Map)['diagnostics']),
          _j(absentDiag),
          reason: 'the night\'s beat counts left with the night');
    });
  });

  group('batch == resumed at the edge', () {
    final beats = synthBeats(const SynthBeats(
        seed: 41,
        seconds: 3 * 3600,
        irregularBurst: (3600, 9000),
        irregularRangeMs: (500, 1100)));

    test('DayRrState folded in chunks, restored from bytes each time, stores '
        'the batch envelope - diagnostics included - at every cut', () {
      var st = DayRrState();
      var at = 0;
      var checked = 0;
      for (final n in [40, 200, 700, 2000, 2013, 4000, 6500, beats.length]) {
        final to = n > beats.length ? beats.length : n;
        if (to <= at) continue;
        st.fold(beats.rr.sublist(at, to), beats.ts.sublist(at, to));
        at = to;
        st = _restart(st);
        final got = st.irregular24hDetailed();
        final want = _refDay(beats.rr.sublist(0, at), beats.ts.sublist(0, at));
        expect(_j(got.diagnostics.toJson()), _j(want.diagnostics.toJson()),
            reason: 'beats=$at');
        expect(got.metric.present, want.metric.present, reason: 'beats=$at');
        checked++;
      }
      expect(checked, greaterThan(5));
      final end = st.irregular24hDetailed();
      expect(end.diagnostics.rrRaw, beats.length);
      expect(end.diagnostics.corrected, isNotNull);
      expect(end.diagnostics.windows!.total, greaterThan(10));
    });

    test('the bundle built from the streamed envelope is byte-identical to the '
        'batch bundle, and carries the diagnostics', () {
      final input = copyDay(incrementalDay())
        ..['day_rr_ts_ms'] = beats.ts
        ..['day_rr_ms'] = beats.rr;
      final oracle = deriveDayBundle(copyDay(input));
      final screen = (_clinical(oracle)['irregular_24h'] as Map)
          .cast<String, dynamic>();
      expect(screen['diagnostics'], isA<Map>(),
          reason: 'the batch bundle stores the diagnostics');

      var st = DayRrState();
      var at = 0;
      for (final to in [900, 2500, 2501, beats.length]) {
        st.fold(beats.rr.sublist(at, to), beats.ts.sublist(at, to));
        at = to;
        st = _restart(st);
      }
      final lean = copyDay(input)
        ..['day_rr_ts_ms'] = <double>[]
        ..['day_rr_ms'] = <double>[]
        ..['day_irregular'] = st.irregular24hDetailed().toJson();
      final got = deriveDayBundle(lean);
      expect(_j(_clinical(got)['irregular_24h']), _j(screen));
      expect(_j(got), _j(oracle),
          reason: 'nothing else in the bundle read the whole-day RR');
    });
  });

  group('old checkpoints are refused, never resumed with counts they never kept',
      () {
    test('the day checkpoint layout moved past 3: a layout-3 checkpoint is a '
        'full pass', () {
      expect(kDayCheckpointFmt, greaterThan(3));
      final cp = DayCheckpoint(
        dayId: 'd',
        algoVersion: kAlgoVersion,
        fmt: 3,
        ctxSig: 'c',
        cpRecTs: 900,
        revVec: encodeRevVec(const {}),
        state: Uint8List(0),
        nightRef: null,
        computedAt: 1,
      );
      final d = decideResume(
          cp: cp, algoVersion: kAlgoVersion, ctxSig: 'c', liveRevs: const {});
      expect(d.resume, isFalse);
      expect(d.reason, 'fmt');
    });

    test('a streamed RR state holding analytics\' version-1 screen checkpoint '
        'does not read', () {
      final beats = synthBeats(const SynthBeats(seed: 5, seconds: 900));
      final st = DayRrState()..fold(beats.rr, beats.ts);
      final w = ResumeWriter();
      st.write(w);
      // The same bytes, with the screen state rewritten the way analytics
      // aa67997 wrote it (version 1, no input-beat or window-total counters).
      final r = ResumeReader(w.takeBytes());
      final n = r.i64();
      final last = r.optF64();
      final j = jsonDecode(utf8.decode(r.bytes(r.count(1)))) as Map<String, dynamic>;
      final screen = (j['i'] as Map).cast<String, dynamic>()
        ..['version'] = 1
        ..remove('nIn')
        ..remove('total');
      final text = utf8.encode(jsonEncode({'c': j['c'], 'i': screen}));
      final old = ResumeWriter()
        ..i64(n)
        ..optF64(last)
        ..i32(text.length)
        ..bytes(Uint8List.fromList(text), text.length);
      expect(() => DayRrState.read(ResumeReader(old.takeBytes())),
          throwsFormatException);
      // And the current layout reads.
      final ok = ResumeWriter();
      st.write(ok);
      expect(DayRrState.read(ResumeReader(ok.takeBytes())).beats, st.beats);
    });
  });

  group('versioned: a payload change re-derives every stored day', () {
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final m = RegExp(r'const int kAlgoVersion = (\d+);').firstMatch(src)!;
    final v = int.parse(m.group(1)!);

    test('kAlgoVersion is bumped past 102 (red until the wiring lands)', () {
      expect(v, greaterThan(102));
    });

    test('the changelog entry sits directly above the constant, names the '
        'version and the diagnostics', () {
      expect(v, greaterThan(102), reason: 'bumped: the entry below is a new one');
      final lines = src.substring(0, m.start).split('\n');
      var i = lines.length - 1;
      while (i >= 0 && lines[i].trim().isEmpty) {
        i--;
      }
      final block = <String>[];
      while (i >= 0 && lines[i].trimLeft().startsWith('//')) {
        block.insert(0, lines[i]);
        i--;
      }
      // The contiguous comment block holds many versions' entries; the new one
      // is the one that starts at this version's own line.
      final from = block.lastIndexWhere((l) => RegExp('^//\\s*v$v\\b').hasMatch(l));
      expect(from, isNonNegative, reason: 'a `// v$v` entry above the constant');
      final text = block.sublist(from).join('\n');
      expect(RegExp(r'diagnostic', caseSensitive: false).hasMatch(text), isTrue);
      expect(RegExp(r'PRV|irregular', caseSensitive: false).hasMatch(text), isTrue);
    });

    test('the analytics pin moved to a full commit SHA that is not the '
        'pre-diagnostics one (invariants 5, 6)', () {
      expect(kAnalyticsPin, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(kAnalyticsPin, isNot('aa67997c430e5656089a70d444d36cc18d6601d0'),
          reason: 'aa67997 has no diagnostics: a bump citing them needs the pin');
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final block = RegExp(r'openstrap_analytics:\n\s+git:[\s\S]*?\n\s+ref: (\S+)')
          .firstMatch(pubspec)!;
      expect(block.group(1), kAnalyticsPin,
          reason: 'pubspec.yaml is the source of truth');
      expect(RegExp(r'^\s+ref: main\s*$', multiLine: true).hasMatch(pubspec), isFalse);
    });
  });

  group('the engine stores them (forced pass over real rows)', () {
    const day = '2025-09-02';
    late Beats beats;
    late int start;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'prv_diagnostics_persist_test.db';
    });

    Future<void> wipe() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    }

    setUp(() async {
      await wipe();
      // 08:00 local on a fixed date: no clock read.
      start = DateTime(2025, 9, 2, 8).millisecondsSinceEpoch ~/ 1000;
      beats = synthBeats(SynthBeats(
          seed: 17,
          startSec: start,
          seconds: 2 * 3600,
          irregularBurst: (2400, 5400)));
      await writeSeconds(beats, synthAccel(23, start, start + 2 * 3600 + 60),
          start, start + 2 * 3600 + 60);
    });
    tearDownAll(wipe);

    test('day_result.payload_json holds clinical.irregular_24h.diagnostics for '
        'the screen the day ran, equal to the analytics oracle', () async {
      await DerivationEngine().runDays(const Profile(), {day}, force: true);
      final row = (await LocalDb.dayResult(day))!;
      final payload =
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      final env = (_clinical(payload)['irregular_24h'] as Map).cast<String, dynamic>();
      expect(env['value'], isA<Map>(), reason: 'fixture: a present 24 h screen');
      expect(env['diagnostics'], isA<Map>(),
          reason: 'persisted with the screen, not recomputed on read');
      // The engine reads beats through the substrate (which may drop some the
      // raw list has), so the oracle here is the stored figures agreeing with
      // each other, not a re-run over the synthetic list.
      final diag = (env['diagnostics'] as Map).cast<String, dynamic>();
      final b = (diag['beats'] as Map).cast<String, dynamic>();
      expect(diag['abstain'], isNull);
      expect(b['nn_kept'], (env['value'] as Map)['n_beats'],
          reason: 'one beat count, stored twice');
      expect(b['rr_raw'], isA<int>());
      expect(b['nn_in'], (b['rr_raw'] as int) - (b['dropped'] as int),
          reason: 'NN = raw beats minus the dropped ones (corrected are replaced)');
      expect((b['rr_raw'] as int), closeTo(beats.length, 100),
          reason: 'the corrector saw the day\'s beats');
      expect(b['corrected'], greaterThan(0));
      final w = (env['diagnostics'] as Map)['windows'] as Map;
      expect(w['total'], greaterThan(10));
      expect(w['flagged'], greaterThan(0), reason: 'the burst flagged windows');
      // No night in this day: the sleep screen abstains with zero beats.
      final sleep = (_clinical(payload)['irregular'] as Map).cast<String, dynamic>();
      expect(((sleep['diagnostics'] as Map)['beats'] as Map)['nn_in'], 0);
    });
  });
}
