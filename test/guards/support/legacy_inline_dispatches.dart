// legacy_inline_dispatches.dart — the dispatches whose closure runs inline code
// instead of a registered entry, so the audit cannot require an entry report
// for them. This is DEBT: the list may only shrink.
//
//   * Each entry is an EXACT label or an ANCHORED pattern (`^...$`), matched
//     against the WHOLE label; the detector refuses an unanchored pattern, so
//     there are no open prefixes
//     (`crossday-input-new-work` is not `crossday-input`).
//   * Adding an entry needs a note in test/guards/BASELINE_CHANGELOG.md, a level-2
//     heading `## legacyInlineDispatch <id>` (checked by
//     [legacyInlineListProblems]), the same review step as raising a rule
//     version.
//   * An entry no run ever dispatches is stale and fails
//     background_dispatch_audit_test.dart; delete it when its closure becomes a
//     registered entry.
//   * A legacy dispatch must be the only one under its token and nothing may
//     report under it (it runs no entry): an unrelated report is a problem.

class LegacyInlineDispatch {
  /// The id the changelog heading names.
  final String id;

  /// Anchored regular expression matched against the whole dispatch label.
  final String pattern;
  final String reason;
  const LegacyInlineDispatch(this.id, this.pattern, this.reason);

  /// FULL-string match: the pattern is wrapped in `^(?:...)$`, so an alternation
  /// like `^a|b$` cannot match a label that only starts with `a` (the
  /// syntactic check in [requireAnchored] cannot see that).
  bool matches(String label) => RegExp('^(?:$pattern)\$').hasMatch(label);

  /// Throws unless [pattern] starts with `^` and ends with `$` (a lint on the
  /// list; [matches] is what enforces the whole-label match).
  void requireAnchored() {
    if (!pattern.startsWith('^') || !pattern.endsWith(r'$')) {
      throw ArgumentError.value(pattern, 'pattern',
          'legacy inline dispatch "$id" must be an anchored pattern (^...\$)');
    }
  }
}

const List<LegacyInlineDispatch> kLegacyInlineDispatches = [
  LegacyInlineDispatch(
    'sleep-staging',
    r'^sleep-staging \d{4}-\d{2}-\d{2}$',
    'DerivationEngine sleep-staging closure handed to _runIsolateCancellable '
        '(baselined dispatcherClosureContract)',
  ),
  LegacyInlineDispatch(
    'crossday-input',
    r'^crossday-input$',
    'DerivationEngine cross-day input closure handed to '
        '_runIsolateCancellable (baselined dispatcherClosureContract)',
  ),
];

/// Problems with the list itself: an entry without a changelog note, a pattern
/// that is not anchored, a duplicate id.
List<String> legacyInlineListProblems(
    List<LegacyInlineDispatch> list, String changelog) {
  final out = <String>[];
  final seen = <String>{};
  for (final e in list) {
    if (!seen.add(e.id)) out.add('duplicate legacy inline id ${e.id}');
    try {
      e.requireAnchored();
    } on ArgumentError catch (x) {
      out.add('${x.message}');
    }
    if (!changelog.contains('\n## legacyInlineDispatch ${e.id}')) {
      out.add('legacy inline dispatch "${e.id}" has no "## legacyInlineDispatch '
          '${e.id}" note in BASELINE_CHANGELOG.md');
    }
  }
  return out;
}
