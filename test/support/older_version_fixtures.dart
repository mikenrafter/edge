// Shared fixtures for the older-calculation marker tests (RULES B.2).
// Not a test itself.
//
// PINNED CONTRACT the green phase must satisfy (keys are ValueKey<String>):
//   older-version-mark:<id>   the asterisk beside a number (text '*'); spoken,
//                             never tappable (no button, no tap action).
//   older-version-note:<id>   the visible note.
// ids: strain / calories / calories_total (Home ring + tile, Day strain),
//      headline / latest / selected (Metric detail), readout (any chart
//      scrub readout: Explorer, month grid, workout bars).
// Note text: 'From an older calculation (v104): <reason sentence>'; with no
// reason, 'From an older calculation (v104)'. Reason sentence is whyFromNote().
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show AnnotationKind, ChartAnnotation, ChartAnnotationLane;

const kReasonRaw = 'need_input:name=age';
const kReasonSentence = 'This metric needs your age, which is not on file.';
const kNoteV104 = 'From an older calculation (v104)';
const kNoteV104Reason = '$kNoteV104: $kReasonSentence';
final kSpoken = RegExp('from an older calculation', caseSensitive: false);

Map<String, dynamic> older({int v = 104, String reason = kReasonRaw}) =>
    {'version': v, 'reason': reason};

/// Every widget keyed older-version-*.
Finder anyOlderMarker() => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('older-version-');
    });

Finder olderMark(String id) => find.byKey(ValueKey('older-version-mark:$id'));
Finder olderNote(String id) => find.byKey(ValueKey('older-version-note:$id'));

/// A stored getChart point `back` days ago, local noon, as the seam stamps it.
Map<String, dynamic> cp(int back, num v, {int? older}) {
  final n = DateTime.now();
  return {
    't': DateTime(n.year, n.month, n.day - back, 12).millisecondsSinceEpoch ~/
        1000,
    'v': v,
    'from_older_version': ?older,
  };
}

/// [n] days ending today; days in [flagged] (days back) carry v104; days in
/// [gaps] are missing.
List<Map<String, dynamic>> series(int n,
        {Set<int> flagged = const {}, Set<int> gaps = const {}, num base = 8}) =>
    [
      for (var back = n - 1; back >= 0; back--)
        if (!gaps.contains(back))
          cp(back, base + (back % 3),
              older: flagged.contains(back) ? 104 : null),
    ];

/// A repository that serves canned charts and day payloads; anything else
/// throws, like the base class.
class OlderRepo extends LocalRepository {
  final Map<String, List<Map<String, dynamic>>> charts;
  final Map<String, Map<String, dynamic>> dayStrain;
  OlderRepo({this.charts = const {}, this.dayStrain = const {}});

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {'points': charts[metric] ?? const []};

  @override
  Future<List<String>> availableDays() async => [
        for (var i = 0; i < 60; i++)
          dayLabelOf(DateTime.now().subtract(Duration(days: i))),
      ];

  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};

  @override
  Future<Map<String, dynamic>> getToday() async => const {};

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async =>
      dayStrain[date] ?? dayStrain['*'] ?? const {};

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
}

/// For a mark inside a tappable card (the card's own node is a button): the
/// mark itself is bare text with no gesture inside it.
void expectBareMark(Finder mark) {
  expect(mark, findsOneWidget);
  expect(
      find.descendant(
          of: mark,
          matching: find.byWidgetPredicate((w) =>
              w is GestureDetector || w is Listener)),
      findsNothing);
}

/// The mark is spoken ([label], by default the English form) and is NOT tappable:
/// its semantics carry no button flag and no tap action.
void expectSpokenNotTappable(WidgetTester t, Finder mark, {Matcher? label}) {
  final d = t.getSemantics(mark).getSemanticsData();
  expect(d.label, label ?? matches(kSpoken));
  expect(d.hasFlag(SemanticsFlag.isButton), isFalse);
  expect(d.hasAction(SemanticsAction.tap), isFalse);
}

/// How many times the whole semantics tree says [what] (default: "from an older
/// calculation"), counting inside merged labels too. Needs
/// `t.ensureSemantics()`.
int spokenCount(WidgetTester t, [Pattern? what]) {
  final re = what is RegExp
      ? what
      : RegExp(what == null ? kSpoken.pattern : RegExp.escape('$what'),
          caseSensitive: false);
  var n = 0;
  void walk(SemanticsNode node) {
    n += re.allMatches(node.getSemanticsData().label).length;
    node.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return n;
}

/// The algorithm-version RANGES (an `until`, not a point mark) on every
/// annotation lane in the tree, left to right as given.
List<ChartAnnotation> olderRanges(WidgetTester t) => [
      for (final lane in t.widgetList<ChartAnnotationLane>(
          find.byType(ChartAnnotationLane)))
        for (final a in lane.set.items)
          if (a.kind == AnnotationKind.algoVersion && a.until != null) a,
    ];

/// Occurrences of the canonical spoken form for [version], whole tree.
int spokenOlder(WidgetTester t, int version) => spokenCount(
    t,
    RegExp('from an older calculation \\(v$version\\)',
        caseSensitive: false));
