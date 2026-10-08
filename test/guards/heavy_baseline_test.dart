// heavy_baseline_test.dart — the baseline's semantics (design 02, rev 1/3/5).
//
// An occurrence is (rule, file, enclosing symbol, element) + multiplicity; no
// line numbers, so unrelated edits do not churn the file. Two comparisons:
//   (1) current tree vs baseline: a NEW occurrence, or MORE instances of a known
//       one, fails (heavy_calc_guard_test.dart applies this to lib/).
//   (2) baseline vs the target branch's baseline: may only SHRINK.
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
        v(HeavyRule.sendableGrammar),
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
        expect(baselineGrowth(base: base, head: head), isEmpty);
      },
      skip: baseRef == null || baseRef.isEmpty
          ? 'set HEAVY_BASELINE_BASE to the target branch ref (CI does)'
          : false,
    );
  });
}
