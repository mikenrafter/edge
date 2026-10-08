// heavy_baseline.dart — occurrence fingerprints for the heavy-calculation
// guard baseline (design 02, rev 1/3/5). No line numbers: an occurrence is
// (rule, file, enclosing symbol, element) plus a multiplicity.
//
// The checked-in file is test/guards/heavy_calc_baseline.json. Two comparisons:
//   1. current tree vs baseline  -> a NEW occurrence (or a higher count) fails.
//   2. baseline vs the target branch's baseline (heavy_baseline_test)
//      -> the file may only shrink, except for the keys of a rule whose VERSION
//      went up against the target branch (kRuleVersions, recorded in the JSON)
//      and that has an entry in test/guards/BASELINE_CHANGELOG.md. That is the
//      one reviewed way to grow it: a deliberate extension of a rule.
//

import 'dart:convert';
import 'dart:io';

import 'heavy_guard.dart';

class HeavyOccurrence {
  final HeavyRule rule;
  final String file;
  final String symbol;
  final String element;
  final int count;
  const HeavyOccurrence({
    required this.rule,
    required this.file,
    required this.symbol,
    required this.element,
    required this.count,
  });

  /// Identity without the count.
  String get key => '${rule.name}|$file|$symbol|$element';

  Map<String, Object?> toJson() => {
        'rule': rule.name,
        'file': file,
        'symbol': symbol,
        'element': element,
        'count': count,
      };

  factory HeavyOccurrence.fromJson(Map<String, Object?> j) => HeavyOccurrence(
        rule: HeavyRule.values.byName(j['rule']! as String),
        file: j['file']! as String,
        symbol: j['symbol']! as String,
        element: j['element']! as String,
        count: j['count']! as int,
      );

  @override
  String toString() => '$key x$count';
}

class HeavyBaseline {
  /// 2 adds `ruleVersions`. A format-1 file (no versions) reads as every rule at
  /// version 1, which is what it was built with.
  static const formatVersion = 2;
  final List<HeavyOccurrence> occurrences;

  /// The rule versions this baseline was built with; a rule that is absent is
  /// at version 1.
  final Map<HeavyRule, int> ruleVersions;

  const HeavyBaseline(this.occurrences, {this.ruleVersions = const {}});

  int versionOf(HeavyRule rule) => ruleVersions[rule] ?? 1;

  Map<String, Object?> toJson() => {
        'version': formatVersion,
        'ruleVersions': {
          for (final r in HeavyRule.values)
            if (r.baselineable) r.name: versionOf(r),
        },
        'occurrences': [for (final o in occurrences) o.toJson()],
      };

  factory HeavyBaseline.fromJson(Map<String, Object?> j) {
    final v = j['version'];
    if (v != 1 && v != formatVersion) {
      throw FormatException('unsupported baseline version $v');
    }
    final versions = (j['ruleVersions'] as Map?)?.cast<String, Object?>() ?? {};
    return HeavyBaseline(
      [
        for (final o in (j['occurrences']! as List))
          HeavyOccurrence.fromJson((o as Map).cast<String, Object?>()),
      ],
      ruleVersions: {
        for (final e in versions.entries)
          HeavyRule.values.byName(e.key): e.value! as int,
      },
    );
  }

  /// Groups [violations] whose rule is baselineable into occurrences with
  /// multiplicity, sorted by key (stable, diff-friendly). Non-baselineable
  /// rules never appear.
  /// The baseline is stamped with [kRuleVersions]: it records the rule versions
  /// it was built with.
  factory HeavyBaseline.fromViolations(List<HeavyViolation> violations) {
    final counts = <String, HeavyOccurrence>{};
    for (final v in violations) {
      if (!v.rule.baselineable) continue;
      final o = HeavyOccurrence(
          rule: v.rule, file: v.file, symbol: v.symbol, element: v.element, count: 1);
      final prev = counts[o.key];
      counts[o.key] = prev == null
          ? o
          : HeavyOccurrence(
              rule: o.rule,
              file: o.file,
              symbol: o.symbol,
              element: o.element,
              count: prev.count + 1);
    }
    final keys = counts.keys.toList()..sort();
    return HeavyBaseline([for (final k in keys) counts[k]!],
        ruleVersions: kRuleVersions);
  }
}

/// Occurrences in [current] that [baseline] does not cover: an unknown key, or
/// the same key with more instances than the baseline allows (the excess
/// count). Every non-baselineable violation is returned as an occurrence of
/// count 1 — it can never be absorbed.
List<HeavyOccurrence> newOccurrences(
  List<HeavyViolation> current,
  HeavyBaseline baseline,
) {
  final allowed = {for (final o in baseline.occurrences) o.key: o.count};
  final fresh = <HeavyOccurrence>[];
  for (final v in current) {
    if (!v.rule.baselineable) {
      fresh.add(HeavyOccurrence(
          rule: v.rule, file: v.file, symbol: v.symbol, element: v.element, count: 1));
    }
  }
  final now = HeavyBaseline.fromViolations(current);
  for (final o in now.occurrences) {
    final excess = o.count - (allowed[o.key] ?? 0);
    if (excess > 0) {
      fresh.add(HeavyOccurrence(
          rule: o.rule, file: o.file, symbol: o.symbol, element: o.element, count: excess));
    }
  }
  return fresh;
}

/// True when [changelog] (the text of test/guards/BASELINE_CHANGELOG.md) has an
/// entry for [rule] at [version]: a level-2 heading `## <ruleName> v<N>` at the
/// start of a line. Prose, deeper headings and indented lines do not count.
bool changelogCovers(String changelog, HeavyRule rule, int version) {
  final entry = RegExp(
    '^## ${RegExp.escape(rule.name)} v$version(?![0-9A-Za-z_])',
    multiLine: true,
  );
  return entry.hasMatch(changelog);
}

/// Human-readable reasons [head] may not replace [base]. Empty when head is a
/// subset (shrink or equal), or when every growing key belongs to a rule whose
/// version went up against [base] AND has an entry in [changelog]
/// (test/guards/BASELINE_CHANGELOG.md). Anything else that grows (a new key, a
/// higher count) is a reason: the only reviewed way to grow the baseline is to
/// extend a rule, bump its version and say why in the changelog.
List<String> baselineGrowth({
  required HeavyBaseline base,
  required HeavyBaseline head,
  String changelog = '',
}) {
  final was = {for (final o in base.occurrences) o.key: o.count};
  final reasons = <String>[];
  for (final o in head.occurrences) {
    final before = was[o.key];
    final String? what;
    if (before == null) {
      what = 'new occurrence ${o.key} x${o.count}';
    } else if (o.count > before) {
      what = '${o.key} grew from $before to ${o.count}';
    } else {
      continue;
    }
    final from = base.versionOf(o.rule), to = head.versionOf(o.rule);
    if (to <= from) {
      reasons.add('$what (rule ${o.rule.name} not bumped: v$from -> v$to; '
          'a rule that grows must be extended and its version raised)');
    } else if (!changelogCovers(changelog, o.rule, to)) {
      reasons.add('$what (rule ${o.rule.name} bumped to v$to but '
          'test/guards/BASELINE_CHANGELOG.md has no "## ${o.rule.name} v$to" '
          'entry)');
    }
  }
  return reasons;
}

/// Reads `test/guards/heavy_calc_baseline.json` as it is at git [ref] in
/// [repoDir] (`git show <ref>:<path>`). Returns null when the file does not
/// exist at that ref (the guard is being introduced); throws a [StateError] that
/// names the ref on any other git failure (unknown ref, not a repo) so CI
/// cannot silently skip the check.
Future<HeavyBaseline?> readBaselineAtRef(
  String ref, {
  required String repoDir,
  String path = 'test/guards/heavy_calc_baseline.json',
}) async {
  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', args, workingDirectory: repoDir);

  final rev = await git(['rev-parse', '--verify', '--quiet', '$ref^{commit}']);
  if (rev.exitCode != 0) {
    throw StateError('baseline ref "$ref" does not resolve in $repoDir '
        '(fetch the target branch first): ${rev.stderr}');
  }
  final exists = await git(['cat-file', '-e', '$ref:$path']);
  if (exists.exitCode != 0) return null;
  final shown = await git(['show', '$ref:$path']);
  if (shown.exitCode != 0) {
    throw StateError('git show $ref:$path failed: ${shown.stderr}');
  }
  return HeavyBaseline.fromJson(
    (jsonDecode(shown.stdout as String) as Map).cast<String, Object?>(),
  );
}
