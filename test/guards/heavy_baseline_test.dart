// heavy_baseline_test.dart — the baseline's semantics (design 02, rev 1/3/5).
//
// An occurrence is (rule, file, enclosing symbol, element) + multiplicity; no
// line numbers, so unrelated edits do not churn the file. Two comparisons:
//   (1) current tree vs baseline: a NEW occurrence, or MORE instances of a known
//       one, fails (heavy_calc_guard_test.dart applies this to lib/).
//   (2) baseline vs the target branch's baseline: may only SHRINK -- except for
//       the keys of a rule whose VERSION (kRuleVersions in support/heavy_guard.dart,
//       recorded in the baseline JSON) went up against the target branch AND has
//       an entry in test/guards/BASELINE_CHANGELOG.md. That is the only reviewed
//       way for the baseline to grow (a deliberate rule extension).
//
// CI passes the target branch like this (.github/workflows/test.yml, pull
// requests only):
//
//   git fetch --no-tags --depth=1 origin "$GITHUB_BASE_REF"
//   HEAVY_BASELINE_BASE="origin/$GITHUB_BASE_REF" flutter test \
//       test/guards/heavy_baseline_test.dart
//
// Locally the shrink test is skipped unless HEAVY_BASELINE_BASE is set, e.g.
//   HEAVY_BASELINE_BASE=main flutter test test/guards/heavy_baseline_test.dart
// If the file does not exist at the base ref the guard is being introduced and
// the comparison passes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/heavy_baseline.dart';
import 'support/heavy_guard.dart';

HeavyViolation v(
  HeavyRule rule, {
  String file = 'a.dart',
  String symbol = 'Foo.bar',
  String element = 'readinessCompute',
}) =>
    HeavyViolation(
      rule: rule,
      file: file,
      symbol: symbol,
      element: element,
      message: 'm',
    );

HeavyOccurrence occ(
  HeavyRule rule, {
  String file = 'a.dart',
  String symbol = 'Foo.bar',
  String element = 'readinessCompute',
  int count = 1,
}) =>
    HeavyOccurrence(
      rule: rule,
      file: file,
      symbol: symbol,
      element: element,
      count: count,
    );

void main() {
  const origin = HeavyRule.heavyOriginOutsideHeavy;

  group('baseline format (real)', () {
    test('JSON round trip keeps every field and writes no line numbers', () {
      final b = HeavyBaseline([occ(origin, count: 3)]);
      final json = jsonEncode(b.toJson());
      expect(json, isNot(contains('line')));
      final back = HeavyBaseline.fromJson(
        (jsonDecode(json) as Map).cast<String, Object?>(),
      );
      expect(back.occurrences.single.toString(), occ(origin, count: 3).toString());
    });

    test('an unknown format version is rejected, not guessed at', () {
      expect(
        () => HeavyBaseline.fromJson({'version': 99, 'occurrences': []}),
        throwsFormatException,
      );
    });
  });

  group('building a baseline from findings', () {
    test('groups identical findings into one occurrence with a count', () {
      final b = HeavyBaseline.fromViolations([v(origin), v(origin), v(origin)]);
      expect(b.occurrences, hasLength(1));
      expect(b.occurrences.single.count, 3);
    });

    test('different symbol, element, file or rule are different occurrences', () {
      final b = HeavyBaseline.fromViolations([
        v(origin),
        v(origin, symbol: 'Foo.baz'),
        v(origin, element: 'stageSleep'),
        v(origin, file: 'b.dart'),
        v(HeavyRule.dispatcherClosureContract),
      ]);
      expect(b.occurrences, hasLength(5));
    });

    test('rules that are not baselineable never enter the baseline', () {
      final b = HeavyBaseline.fromViolations([
        v(HeavyRule.nameMarkerMismatch),
        v(HeavyRule.rootNotRegistered),
        v(HeavyRule.sendableShapeTestMissing),
        v(HeavyRule.platformInHeavy),
        v(origin),
      ]);
      expect(b.occurrences.map((o) => o.rule), [origin]);
    });

    test('output is sorted by key so diffs stay reviewable', () {
      final b = HeavyBaseline.fromViolations([
        v(origin, file: 'z.dart'),
        v(origin, file: 'a.dart'),
        v(origin, file: 'm.dart'),
      ]);
      final keys = b.occurrences.map((o) => o.key).toList();
      expect(keys, [...keys]..sort());
    });
  });

  group('current tree vs baseline', () {
    test('a finding the baseline does not know is a new occurrence', () {
      final fresh = newOccurrences([v(origin)], const HeavyBaseline([]));
      expect(fresh.single.key, occ(origin).key);
    });

    test('a finding covered with the same count is not new', () {
      expect(
        newOccurrences([v(origin), v(origin)], HeavyBaseline([occ(origin, count: 2)])),
        isEmpty,
      );
    });

    test('multiplicity: a third instance of a baselined pair is new', () {
      final fresh = newOccurrences(
        [v(origin), v(origin), v(origin)],
        HeavyBaseline([occ(origin, count: 2)]),
      );
      expect(fresh, hasLength(1));
      expect(fresh.single.count, 1, reason: 'only the excess instance');
    });

    test('fewer instances than baselined is fine (the baseline may shrink)', () {
      expect(
        newOccurrences([v(origin)], HeavyBaseline([occ(origin, count: 5)])),
        isEmpty,
      );
    });

    test('a moved line is not a new occurrence (identity has no line)', () {
      // Same file/symbol/element in the new tree: covered, whatever the line.
      expect(
        newOccurrences([v(origin)], HeavyBaseline([occ(origin)])),
        isEmpty,
      );
    });

    test('a non-baselineable finding is new even if someone listed it', () {
      final fresh = newOccurrences(
        [v(HeavyRule.nameMarkerMismatch)],
        HeavyBaseline([occ(HeavyRule.nameMarkerMismatch)]),
      );
      expect(fresh, hasLength(1));
    });
  });

  group('baseline may only shrink against the target branch', () {
    test('equal or smaller head has no growth', () {
      final base = HeavyBaseline([occ(origin, count: 3), occ(origin, symbol: 'X.y')]);
      expect(baselineGrowth(base: base, head: base), isEmpty);
      expect(
        baselineGrowth(base: base, head: HeavyBaseline([occ(origin, count: 2)])),
        isEmpty,
      );
      expect(baselineGrowth(base: base, head: const HeavyBaseline([])), isEmpty);
    });

    test('a new key is growth and the reason names it', () {
      final reasons = baselineGrowth(
        base: HeavyBaseline([occ(origin)]),
        head: HeavyBaseline([occ(origin), occ(origin, symbol: 'New.thing')]),
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('New.thing'));
    });

    test('a higher count for a known key is growth', () {
      final reasons = baselineGrowth(
        base: HeavyBaseline([occ(origin, count: 2)]),
        head: HeavyBaseline([occ(origin, count: 3)]),
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('readinessCompute'));
    });
  });

  group('baseline growth is reviewed through rule versions', () {
    const changelogV2 = '# Baseline changelog\n\n'
        '## heavyOriginOutsideHeavy v2 - stored-data iteration\n\n'
        'Why the rule grew.\n';
    final base = HeavyBaseline([occ(origin)]);
    HeavyBaseline head({int version = 1}) => HeavyBaseline(
          [occ(origin), occ(origin, symbol: 'New.thing')],
          ruleVersions: {origin: version},
        );

    test('growth of a bumped rule WITH a changelog entry passes', () {
      expect(
        baselineGrowth(base: base, head: head(version: 2), changelog: changelogV2),
        isEmpty,
      );
    });

    test('a higher count of a bumped rule with a changelog entry passes', () {
      expect(
        baselineGrowth(
          base: HeavyBaseline([occ(origin)]),
          head: HeavyBaseline([occ(origin, count: 4)],
              ruleVersions: const {origin: 2}),
          changelog: changelogV2,
        ),
        isEmpty,
      );
    });

    test('growth of a bumped rule WITHOUT a changelog entry fails', () {
      final reasons = baselineGrowth(
        base: base,
        head: head(version: 2),
        changelog: '# Baseline changelog\n',
      );
      expect(reasons, isNotEmpty);
      expect(reasons.join('\n'), contains('BASELINE_CHANGELOG.md'));
      expect(reasons.join('\n'), contains('heavyOriginOutsideHeavy'));
    });

    test('a changelog entry for another version does not cover the bump', () {
      expect(
        baselineGrowth(base: base, head: head(version: 3), changelog: changelogV2),
        isNotEmpty,
      );
    });

    test('a changelog entry for another rule does not cover the bump', () {
      const other = '## sendableGrammar v2 - x\n';
      expect(
        baselineGrowth(base: base, head: head(version: 2), changelog: other),
        isNotEmpty,
      );
    });

    test('growth of an UNBUMPED rule fails even with a changelog entry', () {
      final reasons = baselineGrowth(
        base: base,
        head: head(version: 1),
        changelog: changelogV2,
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('New.thing'));
      expect(reasons.single, contains('not bumped'));
    });

    test('a bump of one rule does not license growth of another', () {
      final reasons = baselineGrowth(
        base: base,
        head: HeavyBaseline(
          [occ(origin), occ(HeavyRule.sendableGrammar, symbol: 'New.thing')],
          ruleVersions: const {origin: 2},
        ),
        changelog: changelogV2,
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('sendableGrammar'));
    });

    test('shrinking always passes, bumped or not, documented or not', () {
      final big = HeavyBaseline([occ(origin, count: 3), occ(origin, symbol: 'X.y')]);
      for (final v in [1, 2]) {
        expect(
          baselineGrowth(
            base: big,
            head: HeavyBaseline([occ(origin)], ruleVersions: {origin: v}),
          ),
          isEmpty,
        );
      }
    });

    test('a bump without any growth needs no changelog entry', () {
      expect(
        baselineGrowth(
          base: base,
          head: HeavyBaseline([occ(origin)], ruleVersions: const {origin: 2}),
        ),
        isEmpty,
      );
    });

    test("the base ref's versions are what the head is compared with", () {
      // Base already at v2: v2 on the head is NOT a bump.
      final base2 = HeavyBaseline([occ(origin)], ruleVersions: const {origin: 2});
      expect(
        baselineGrowth(base: base2, head: head(version: 2), changelog: changelogV2),
        isNotEmpty,
      );
    });

    test('a baseline without ruleVersions (format 1) reads as every rule at v1',
        () {
      final old = HeavyBaseline.fromJson({
        'version': 1,
        'occurrences': [occ(origin).toJson()],
      });
      expect(old.versionOf(origin), 1);
      expect(old.versionOf(HeavyRule.sendableGrammar), 1);
    });

    test('rule versions survive the JSON round trip', () {
      final b = HeavyBaseline([occ(origin)],
          ruleVersions: const {origin: 2, HeavyRule.sendableGrammar: 3});
      final back = HeavyBaseline.fromJson(
        (jsonDecode(jsonEncode(b.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back.versionOf(origin), 2);
      expect(back.versionOf(HeavyRule.sendableGrammar), 3);
      expect(back.versionOf(HeavyRule.unresolvedInvocation), 1);
    });

    test("a baseline built from findings records the guard's kRuleVersions", () {
      final b = HeavyBaseline.fromViolations([v(origin)]);
      for (final r in HeavyRule.values.where((r) => r.baselineable)) {
        expect(b.versionOf(r), kRuleVersions[r], reason: r.name);
      }
    });

    test('every baselineable rule has a version of at least 1, no others', () {
      expect(kRuleVersions.keys.toSet(),
          HeavyRule.values.where((r) => r.baselineable).toSet());
      for (final e in kRuleVersions.entries) {
        expect(e.value, greaterThanOrEqualTo(1), reason: e.key.name);
      }
    });
  });

  // P2.0b adds two rules (storedPayloadDecodeOutsideHeavy, rawTableRowLoopOutsideHeavy)
  // at version 1. A rule absent from a base baseline that records rule versions
  // did not exist there: its first keys are reviewed growth, licensed by the
  // changelog entry `## <rule> v1` and not by a version raise (v1 is its first
  // version, nothing to raise). Today baselineGrowth reads an absent rule as v1,
  // so v1 -> v1 is "not bumped" and the first keys could never be written.
  group('a rule that is new in the head (first version, P2.0b)', () {
    const fresh = HeavyRule.storedPayloadDecodeOutsideHeavy;
    const changelog = '## storedPayloadDecodeOutsideHeavy v1 - stored payload decode\n\n'
        'Why the rule exists.\n';
    // A format-2 base: it records versions, and does not know `fresh`.
    final base = HeavyBaseline(
      [occ(origin)],
      ruleVersions: const {origin: 2, HeavyRule.sendableGrammar: 2},
    );
    HeavyBaseline head({Map<HeavyRule, int>? versions}) => HeavyBaseline(
          [occ(origin), occ(fresh, symbol: 'New.thing')],
          ruleVersions: versions ??
              const {origin: 2, HeavyRule.sendableGrammar: 2, fresh: 1},
        );

    test('its first keys pass with a changelog entry for v1', () {
      expect(baselineGrowth(base: base, head: head(), changelog: changelog),
          isEmpty);
    });

    test('its first keys fail without the changelog entry', () {
      final reasons = baselineGrowth(
          base: base, head: head(), changelog: '# Baseline changelog\n');
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('storedPayloadDecodeOutsideHeavy v1'));
      expect(reasons.single, contains('BASELINE_CHANGELOG.md'));
    });

    test('a changelog entry for another version or rule does not cover it', () {
      for (final log in [
        '## storedPayloadDecodeOutsideHeavy v2 - x\n',
        '## rawTableRowLoopOutsideHeavy v1 - x\n',
      ]) {
        expect(baselineGrowth(base: base, head: head(), changelog: log),
            isNotEmpty,
            reason: log);
      }
    });

    test('once the base knows the rule at v1, more keys at v1 are not licensed',
        () {
      final known = HeavyBaseline(
        [occ(origin), occ(fresh)],
        ruleVersions: const {origin: 2, HeavyRule.sendableGrammar: 2, fresh: 1},
      );
      final reasons =
          baselineGrowth(base: known, head: head(), changelog: changelog);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('not bumped'));
    });

    test('a baseline without ruleVersions (format 1) still reads every rule as '
        'v1: no new-rule licence', () {
      final old = HeavyBaseline([occ(origin)]);
      final reasons = baselineGrowth(
        base: old,
        head: HeavyBaseline([occ(origin), occ(fresh, symbol: 'New.thing')],
            ruleVersions: const {fresh: 1}),
        changelog: changelog,
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('not bumped'));
    });

    test('one new rule does not license growth of another rule', () {
      final reasons = baselineGrowth(
        base: base,
        head: HeavyBaseline(
          [
            occ(origin),
            occ(fresh, symbol: 'New.thing'),
            occ(HeavyRule.sendableGrammar, symbol: 'New.other'),
          ],
          ruleVersions: const {origin: 2, HeavyRule.sendableGrammar: 2, fresh: 1},
        ),
        changelog: changelog,
      );
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('sendableGrammar'));
    });

    test('the two P2.0b rules start at version 1 and are baselineable', () {
      for (final r in [
        HeavyRule.storedPayloadDecodeOutsideHeavy,
        HeavyRule.rawTableRowLoopOutsideHeavy,
      ]) {
        expect(r.baselineable, isTrue, reason: r.name);
        expect(kRuleVersions[r], 1, reason: r.name);
      }
    });

    test('widening the RowBatch cheap members (first/last) is a shrink: that '
        "rule's version does not move", () {
      expect(kRuleVersions[HeavyRule.rowBatchIterationOutsideHeavy], 1);
    });
  });

  group('BASELINE_CHANGELOG.md entries', () {
    test('an entry is a level-2 heading naming the rule and vN', () {
      const log = '## heavyOriginOutsideHeavy v2 - why\ntext\n## sendableGrammar v10\n';
      expect(changelogCovers(log, origin, 2), isTrue);
      expect(changelogCovers(log, HeavyRule.sendableGrammar, 10), isTrue);
      expect(changelogCovers(log, HeavyRule.sendableGrammar, 1), isFalse);
      expect(changelogCovers(log, origin, 3), isFalse);
    });

    test('a mention in prose, a code fence or a deeper heading is not an entry',
        () {
      const log = 'We bumped heavyOriginOutsideHeavy v2 last week.\n'
          '### heavyOriginOutsideHeavy v2\n'
          '    ## heavyOriginOutsideHeavy v2\n';
      expect(changelogCovers(log, origin, 2), isFalse);
    });

    test('a rule name that merely starts with another does not match', () {
      const log = '## workerEntryNotInitialisedX v2\n';
      expect(changelogCovers(log, HeavyRule.workerEntryNotInitialised, 2), isFalse);
    });
  });

  group('reading the target branch (git show <ref>:path)', () {
    late Directory repo;

    Future<ProcessResult> git(List<String> args) => Process.run(
          'git',
          ['-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args],
          workingDirectory: repo.path,
        );

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('heavy_baseline_git_');
      await git(['init', '-q', '-b', 'main']);
    });

    tearDown(() => repo.delete(recursive: true));

    test('returns the baseline as committed at the ref, not the work tree', () async {
      final f = File('${repo.path}/test/guards/heavy_calc_baseline.json')
        ..createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(HeavyBaseline([occ(origin, count: 2)]).toJson()));
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      // Work tree moves on; the ref must not.
      f.writeAsStringSync(jsonEncode(const HeavyBaseline([]).toJson()));

      final got = await readBaselineAtRef('main', repoDir: repo.path);
      expect(got, isNotNull);
      expect(got!.occurrences.single.count, 2);
    });

    test('a file that does not exist at the ref means "being introduced"', () async {
      File('${repo.path}/README').writeAsStringSync('x');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      expect(await readBaselineAtRef('main', repoDir: repo.path), isNull);
    });

    test('an unknown ref fails loudly instead of skipping the check', () async {
      File('${repo.path}/README').writeAsStringSync('x');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
      expect(
        () => readBaselineAtRef('no-such-ref', repoDir: repo.path),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('no-such-ref'))),
      );
    });
  });

  group('checked-in baseline vs the target branch', () {
    final baseRef = Platform.environment['HEAVY_BASELINE_BASE'];

    test(
      'test/guards/heavy_calc_baseline.json only shrinks',
      () async {
        final base = await readBaselineAtRef(baseRef!, repoDir: Directory.current.path);
        if (base == null) return; // introduced by this change
        final head = HeavyBaseline.fromJson(
          (jsonDecode(File('test/guards/heavy_calc_baseline.json').readAsStringSync())
                  as Map)
              .cast<String, Object?>(),
        );
        final changelog =
            File('test/guards/BASELINE_CHANGELOG.md').readAsStringSync();
        expect(
          baselineGrowth(base: base, head: head, changelog: changelog),
          isEmpty,
        );
      },
      skip: baseRef == null || baseRef.isEmpty
          ? 'set HEAVY_BASELINE_BASE to the target branch ref (CI does)'
          : false,
    );
  });
}
