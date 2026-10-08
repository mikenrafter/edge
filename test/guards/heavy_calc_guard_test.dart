// heavy_calc_guard_test.dart — design 02: heavy calculation lives in marked
// `@heavy` functions that run only inside a registered worker (AGENTS.md
// §3.10, §3.8, §6). Applies the resolved-AST guard (package:analyzer, no lint
// plugin) to the real `lib/`.
//
// The RULES are specified by the synthetic packages in heavy_guard_fixtures_test.dart;
// this file only answers "does lib/ obey them, modulo the shrinking baseline?".
//
// test/guards/heavy_calc_baseline.json holds every LEGACY occurrence (step 1
// generated it from the tree without changing code). It may only shrink: a new
// occurrence fails here, and heavy_baseline_test.dart compares the file against
// the target branch.
//
// New `unresolvedInvocation` findings fail unless fingerprinted in
// kUnresolvedOk; only EXISTING ones are in the baseline.
//
// Regenerate (shrinking, or the first time):
//   HEAVY_GUARD_WRITE_BASELINE=1 flutter test test/guards/heavy_calc_guard_test.dart \
//       --plain-name 'write baseline'
// Refuses to write a baseline that grows an existing one.

@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/raw_readers.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

import 'support/heavy_baseline.dart';
import 'support/heavy_guard.dart';

const _baselinePath = 'test/guards/heavy_calc_baseline.json';

HeavyBaseline _loadBaseline(String repoRoot) {
  final f = File('$repoRoot/$_baselinePath');
  expect(
    f.existsSync(),
    isTrue,
    reason: '$_baselinePath is missing: generate the initial baseline from the '
        'current tree (step 1 GREEN); it may only shrink afterwards',
  );
  return HeavyBaseline.fromJson(
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
  );
}

void main() {
  final repoRoot = Directory.current.path;
  HeavyGuardResult? cached;
  Future<HeavyGuardResult> analysis() async {
    if (cached != null) return cached!;
    final sw = Stopwatch()..start();
    cached = await analyzeHeavyGuard(HeavyGuardConfig.edge(repoRoot));
    // Wall time of resolving + checking the real lib/ (monotonic, for the log).
    // ignore: avoid_print
    print('heavy guard: analysed lib/ in ${sw.elapsed.inSeconds}s, '
        '${cached!.violations.length} findings: '
        '${{for (final r in HeavyRule.values) r.name: cached!.of(r).length}..removeWhere((_, n) => n == 0)}');
    return cached!;
  }

  tearDownAll(disposeHeavyGuardCaches);

  group('baseline file', () {
    test('test/guards/heavy_calc_baseline.json exists and parses', () {
      expect(_loadBaseline(repoRoot).occurrences, isNotNull);
    });

    test('lists only baselineable rules, sorted, with positive counts', () {
      final b = _loadBaseline(repoRoot);
      for (final o in b.occurrences) {
        expect(o.rule.baselineable, isTrue, reason: '$o');
        expect(o.count, greaterThan(0), reason: '$o');
        expect(o.file, isNot(startsWith('lib/')),
            reason: 'file is relative to lib/: $o');
      }
      final keys = b.occurrences.map((o) => o.key).toList();
      expect(keys, [...keys]..sort(), reason: 'keep the file diff-friendly');
      expect(keys.toSet(), hasLength(keys.length), reason: 'duplicate keys');
    });
  });

  group('lib/ against the guard', () {
    test('no occurrence outside the baseline (new heavy work on the UI isolate)',
        () async {
      final b = _loadBaseline(repoRoot);
      final fresh = newOccurrences((await analysis()).violations, b);
      expect(
        fresh,
        isEmpty,
        reason: 'new occurrence(s):\n${fresh.join('\n')}\n'
            'Move the work into a registered @heavy worker entry '
            '(lib/util/worker_entries.dart) instead of growing the baseline.',
      );
    });

    test('structure rules have no findings at all (never baselineable)', () async {
      final r = await analysis();
      final structural = [
        for (final v in r.violations)
          if (!v.rule.baselineable) v,
      ];
      expect(structural, isEmpty, reason: structural.join('\n'));
    });

    test('every kWorkerEntries symbol resolves to exactly one @heavy function',
        () async {
      final r = await analysis();
      const registryRules = {
        HeavyRule.registryEntryUnresolved,
        HeavyRule.registryEntryAmbiguous,
        HeavyRule.registryEntryDuplicate,
        HeavyRule.registryEntryNotHeavy,
        HeavyRule.registryDispatcherMismatch,
        HeavyRule.registryEntryNeverDispatched,
        HeavyRule.rootNotRegistered,
      };
      expect(r.rules.intersection(registryRules), isEmpty,
          reason: r.violations.where((v) => registryRules.contains(v.rule)).join('\n'));
      expect(kWorkerEntries.map((e) => e.symbol).toSet().length,
          kWorkerEntries.length);
    });

    test('registered raw readers return RowBatch; no new unregistered reader',
        () async {
      final r = await analysis();
      expect(r.of(HeavyRule.rawReaderWrongReturnType), isEmpty,
          reason: r.of(HeavyRule.rawReaderWrongReturnType).join('\n'));
      // Legacy LocalDb methods that touch raw tables are baselined; a NEW one
      // must be registered in kRawReaders (and return RowBatch).
      final b = _loadBaseline(repoRoot);
      final fresh = newOccurrences(
        r.violations.where((v) => v.rule == HeavyRule.rawReaderUnregistered).toList(),
        b,
      );
      expect(fresh, isEmpty, reason: fresh.join('\n'));
      expect(kRawReaders.map((e) => e.symbol).toSet().length, kRawReaders.length);
    });

    test('every @SendableShape entry type has its sendable_<entry>_test', () async {
      final r = await analysis();
      expect(r.of(HeavyRule.sendableShapeTestMissing), isEmpty);
    });

    test('@live functions neither call heavy work nor loop unboundedly', () async {
      final r = await analysis();
      final live = [
        ...r.of(HeavyRule.liveCallsHeavy),
        ...r.of(HeavyRule.liveUnboundedLoop),
        ...r.of(HeavyRule.liveAndHeavy),
        ...r.of(HeavyRule.liveBudgetTestMissing),
      ];
      expect(live, isEmpty, reason: live.join('\n'));
    });

    test('@heavy bodies touch no platform, DB, BLE or notification API', () async {
      final r = await analysis();
      expect(r.of(HeavyRule.platformInHeavy), isEmpty,
          reason: r.of(HeavyRule.platformInHeavy).join('\n'));
    });
  });

  test(
    'write baseline',
    () async {
      final file = File('$repoRoot/$_baselinePath');
      final fresh = HeavyBaseline.fromViolations((await analysis()).violations);
      if (file.existsSync()) {
        final old = HeavyBaseline.fromJson(
          (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
        );
        final growth = baselineGrowth(base: old, head: fresh);
        expect(growth, isEmpty,
            reason: 'refusing to grow the baseline:\n${growth.join('\n')}');
      }
      file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(fresh.toJson())}\n');
    },
    skip: Platform.environment['HEAVY_GUARD_WRITE_BASELINE'] == '1'
        ? false
        : 'set HEAVY_GUARD_WRITE_BASELINE=1 to (re)generate the baseline',
  );
}
