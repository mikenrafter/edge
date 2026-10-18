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
// Refuses to write a baseline that grows an existing one, EXCEPT for the keys
// of a rule whose version (kRuleVersions in support/heavy_guard.dart) went up
// against the file being replaced and has an entry in
// test/guards/BASELINE_CHANGELOG.md. There is no override flag: the same rule
// CI applies against the target branch applies when writing.

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

    test('records exactly the rule versions the guard is at (kRuleVersions)', () {
      final b = _loadBaseline(repoRoot);
      for (final r in HeavyRule.values.where((r) => r.baselineable)) {
        expect(b.versionOf(r), kRuleVersions[r],
            reason: '${r.name}: regenerate the baseline after bumping a rule '
                'version');
      }
    });

    test('every rule above v1 has its BASELINE_CHANGELOG.md entry', () {
      final log = File('$repoRoot/test/guards/BASELINE_CHANGELOG.md');
      expect(log.existsSync(), isTrue, reason: 'test/guards/BASELINE_CHANGELOG.md');
      final text = log.readAsStringSync();
      for (final e in kRuleVersions.entries.where((e) => e.value > 1)) {
        for (var v = 2; v <= e.value; v++) {
          expect(changelogCovers(text, e.key, v), isTrue,
              reason: 'missing "## ${e.key.name} v$v" in BASELINE_CHANGELOG.md');
        }
      }
    });

    test('a rule added after the first guard commit has its v1 changelog entry',
        () {
      // New rules start at v1 (P2.0b); the baseline growth they cause is
      // licensed by `## <rule> v1` in BASELINE_CHANGELOG.md.
      final text =
          File('$repoRoot/test/guards/BASELINE_CHANGELOG.md').readAsStringSync();
      for (final r in const [
        HeavyRule.storedPayloadDecodeOutsideHeavy,
        HeavyRule.rawTableRowLoopOutsideHeavy,
      ]) {
        expect(changelogCovers(text, r, kRuleVersions[r]!), isTrue,
            reason: 'missing "## ${r.name} v${kRuleVersions[r]}" in '
                'BASELINE_CHANGELOG.md');
      }
    });

    test('kMigrationMethods names real LocalDb methods, each with a reason', () {
      final src = File('$repoRoot/lib/data/db.dart').readAsStringSync();
      for (final m in kMigrationMethods) {
        expect(m.reason.trim(), isNotEmpty, reason: m.symbol);
        final name = m.symbol.split('.').last;
        expect(m.symbol, startsWith('LocalDb.'));
        expect(RegExp('[ >]${RegExp.escape(name)}\\(').hasMatch(src), isTrue,
            reason: '${m.symbol} is not a method of lib/data/db.dart (stale)');
      }
      expect(kMigrationMethods.map((m) => m.symbol).toSet(),
          hasLength(kMigrationMethods.length));
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

    // P2.0b: the two new rules must find the sites the design names, or the
    // baseline would not carry them and later phases would have nothing to
    // retire. The keys themselves enter the baseline in the GREEN commit.
    test('storedPayloadDecodeOutsideHeavy finds the legacy payload decoders',
        () async {
      final found = {
        for (final v in (await analysis()).of(HeavyRule.storedPayloadDecodeOutsideHeavy))
          '${v.file} :: ${v.symbol}',
      };
      expect(
        found,
        containsAll(<String>[
          // SeriesCodec.encodePayloadJson and the payload_json column.
          'data/db.dart :: LocalDb.putDayResult',
        ]),
        reason: found.join('\n'),
      );
    });

    test('rawTableRowLoopOutsideHeavy finds getDeviceChart and '
        'SampleArchiver._archiveDevice', () async {
      final r = (await analysis()).of(HeavyRule.rawTableRowLoopOutsideHeavy);
      final found = {for (final v in r) '${v.file} :: ${v.symbol} -> ${v.element}'};
      expect(
        found,
        containsAll(<String>[
          'data/local_repository_impl.dart :: LocalRepositoryImpl.getDeviceChart'
              ' -> decoded_onehz',
          'data/sample_archive.dart :: SampleArchiver._archiveDevice'
              ' -> decoded_onehz',
        ]),
        reason: found.join('\n'),
      );
      expect(r.where((v) => v.symbol.startsWith('LocalDb.')), isEmpty,
          reason: 'LocalDb is the raw-reader registry\'s business, not this rule\'s');
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
      // Growth is allowed only for a rule whose version went up and which has
      // a BASELINE_CHANGELOG.md entry (the same rule CI applies to the PR).
      if (file.existsSync()) {
        final old = HeavyBaseline.fromJson(
          (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
        );
        final growth = baselineGrowth(
          base: old,
          head: fresh,
          changelog:
              File('$repoRoot/test/guards/BASELINE_CHANGELOG.md').readAsStringSync(),
        );
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
