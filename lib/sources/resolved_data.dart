// Resolved data: who owned each stretch of one signal, and why.
//
// A READ SEAM. It reads `device_coverage`, `signal_priority`,
// `metric_series_version` (the order a day derived under) and a retained-hr
// mean from `decoded_onehz`. It computes no analytics and imports nothing from
// compute/.
//
// THE OWNERSHIP RULE IS NOT REWRITTEN HERE. Owners come from
// `resolveOwnership` and the candidate list from `effectivePriority`, the same
// two functions the derivation engine calls, so the view and the engine agree
// on every contested stretch (hysteresis included). What this file adds is
// honesty the engine deliberately does not have: the engine's one-candidate
// shortcut hands a lone device a whole window, gaps and all, so a view that
// reused it would show a hole in the only device's coverage as continuous
// recording. Here a stretch nobody recorded is a gap, and a covered stretch
// shorter than the handover span is thin data and also absent.

import '../ble/adapters/signals.dart' show InputSignal;
import '../data/coverage_resolver.dart';
import '../data/day_label.dart';
import '../data/db.dart' show LocalDb;

/// A covered stretch shorter than this is not used: the span ownership needs
/// before it will hand a stretch from one real device to another.
const int kThinCoverageSeconds =
    kOwnershipHysteresisBuckets * kOwnershipBucketSeconds;

/// Two sources' mean heart rate over a shared stretch within this many bpm
/// agree. Agreement is reported beside the owner and never changes it.
const double kAgreementToleranceBpm = 5;

/// One stretch of one signal. `winner` is null for a gap. See
/// test/sources/sources_contract.md for the field meanings.
class ResolvedInterval {
  final String signal;
  final int start, end;
  final String kind, agreement, reasonCode, reason;
  final String? winner;
  final List<String> alternatives;
  final Map<String, double> values;

  const ResolvedInterval({
    required this.signal,
    required this.start,
    required this.end,
    required this.kind,
    required this.winner,
    required this.alternatives,
    required this.agreement,
    required this.reasonCode,
    required this.reason,
    required this.values,
  });

  Map<String, Object?> toJson() => {
        'signal': signal,
        'start': start,
        'end': end,
        'kind': kind,
        'winner': winner,
        'alternatives': alternatives,
        'agreement': agreement,
        'reasonCode': reasonCode,
        'reason': reason,
        'values': values,
      };
}

typedef _Stretch = ({String deviceId, int start, int end});

/// One order in force over `[from, to)`. [isDefault] is true when nothing was
/// stored and the primary owns by rule (`defaultPrimary`).
typedef _Run = ({int from, int to, List<String> order, bool isDefault});

/// Resolves [signal] over `[from, to)` (epoch seconds). Intervals tile the
/// window.
///
/// A local day before [now] that already derived is resolved under the order
/// stamped on it (`metric_series_version.priority_hash`); every other stretch
/// uses the order stored now. A reorder therefore moves current and future
/// stretches only, until the explicit history rebuild restamps those days.
///
/// Signals the engine does not own exclusively (steps, `hrSparse`, …) return
/// no intervals: there is no single owner to show.
Future<List<ResolvedInterval>> resolveIntervals({
  required InputSignal signal,
  required int from,
  required int to,
  required DateTime now,
}) async {
  if (to <= from || !kExclusiveOwnershipSignals.contains(signal)) return const [];

  // Read a margin on both sides so a stretch that straddles the window edge is
  // measured at its real length, not clipped into "thin".
  final raw = await LocalDb.coverageIntervals(
    signal,
    from - kThinCoverageSeconds,
    to + kThinCoverageSeconds,
  );
  final stretches = _mergePerDevice(raw);
  final usable = [
    for (final s in stretches)
      if (s.end - s.start >= kThinCoverageSeconds) s,
  ];
  final thin = [
    for (final s in stretches)
      if (s.end - s.start < kThinCoverageSeconds) s,
  ];

  final stored = await LocalDb.signalPriority(signal);
  final current = effectivePriority(stored, [for (final s in usable) s.deviceId]);
  final runs = await _runs(signal, from, to, now, current, stored.isEmpty);

  final spans = <OwnedSpan>[];
  for (final run in runs) {
    spans.addAll(resolveOwnership(
      coverage: [
        for (final s in usable) (deviceId: s.deviceId, start: s.start, end: s.end),
      ],
      priority: run.order,
      from: run.from,
      to: run.to,
      signal: signal,
      // The view shows what was recorded; see the header.
      identityShortCircuit: false,
    ));
  }

  // Elementary segments: nothing changes inside one, so each device either
  // covers the whole segment or none of it.
  final cuts = <int>{from, to};
  void cut(int t) {
    if (t > from && t < to) cuts.add(t);
  }

  for (final s in spans) {
    cut(s.start);
    cut(s.end);
  }
  for (final s in [...usable, ...thin]) {
    cut(s.start);
    cut(s.end);
  }
  for (final r in runs) {
    cut(r.from);
  }
  final edges = cuts.toList()..sort();

  final out = <ResolvedInterval>[];
  for (var i = 0; i + 1 < edges.length; i++) {
    final a = edges[i], b = edges[i + 1];
    final run = runs.firstWhere((r) => a >= r.from && a < r.to);
    final covering = [
      for (final s in usable)
        if (s.start <= a && s.end >= b) s.deviceId,
    ];
    final owner = spanAt(spans, a)?.deviceId;
    final seg = _segment(
      signal: signal,
      start: a,
      end: b,
      covering: covering,
      owner: owner,
      thin: thin.any((s) => s.start <= a && s.end >= b),
      run: run,
    );
    final last = out.isEmpty ? null : out.last;
    if (last != null && _sameRow(last, seg)) {
      out[out.length - 1] = _withEnd(last, b);
    } else {
      out.add(seg);
    }
  }

  // Agreement needs retained values, so it is read only for contested stretches.
  if (signal != InputSignal.hr1Hz) return out;
  return [
    for (final r in out)
      r.kind == 'overlap' ? await _withAgreement(r) : r,
  ];
}

/// Per device, union the overlapping or touching intervals into stretches.
List<_Stretch> _mergePerDevice(List<CoverageInterval> raw) {
  final byDevice = <String, List<CoverageInterval>>{};
  for (final iv in raw) {
    if (iv.end > iv.start) (byDevice[iv.deviceId] ??= []).add(iv);
  }
  final out = <_Stretch>[];
  for (final e in byDevice.entries) {
    final ivs = e.value..sort((a, b) => a.start.compareTo(b.start));
    var s = ivs.first.start, en = ivs.first.end;
    for (final iv in ivs.skip(1)) {
      if (iv.start <= en) {
        if (iv.end > en) en = iv.end;
      } else {
        out.add((deviceId: e.key, start: s, end: en));
        s = iv.start;
        en = iv.end;
      }
    }
    out.add((deviceId: e.key, start: s, end: en));
  }
  return out;
}

/// Splits the window at local midnights into days, gives each day the order it
/// is judged under, and joins neighbours that share one so hysteresis runs
/// across them unbroken.
Future<List<_Run>> _runs(
  InputSignal signal,
  int from,
  int to,
  DateTime now,
  List<String> current,
  bool currentIsDefault,
) async {
  final today = dayLabelOf(now);
  final first = DateTime.fromMillisecondsSinceEpoch(from * 1000);
  final stamps = await LocalDb.priorityStampsByDay(
    dayLabelOf(first),
    // Only days before today can be judged by a stamp.
    dayLabelOf(DateTime.fromMillisecondsSinceEpoch((to - 1) * 1000)),
  );
  final runs = <_Run>[];
  var cursor = from;
  var day = DateTime(first.year, first.month, first.day);
  while (cursor < to) {
    // A calendar step, not +86400: a day is 23 or 25 h across DST.
    day = DateTime(day.year, day.month, day.day + 1);
    final next = day.millisecondsSinceEpoch ~/ 1000;
    final end = next < to ? next : to;
    final label = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(cursor * 1000));
    final stamped = label.compareTo(today) < 0 && stamps[label] != null
        ? parsePriorityKey(stamps[label]!)[signal.name]
        : null;
    final order = stamped ?? current;
    final isDefault = stamped == null
        ? currentIsDefault
        : stamped.length == 1 && stamped.first == LocalDb.kPrimaryDeviceId;
    final last = runs.isEmpty ? null : runs.last;
    if (last != null && _sameList(last.order, order) && last.isDefault == isDefault) {
      runs[runs.length - 1] =
          (from: last.from, to: end, order: order, isDefault: isDefault);
    } else {
      runs.add((from: cursor, to: end, order: order, isDefault: isDefault));
    }
    cursor = end;
  }
  return runs;
}

bool _sameList(List<String> a, List<String> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

const _minutes = kThinCoverageSeconds ~/ 60;

ResolvedInterval _segment({
  required InputSignal signal,
  required int start,
  required int end,
  required List<String> covering,
  required String? owner,
  required bool thin,
  required _Run run,
}) {
  ResolvedInterval gap(String code, String reason, List<String> alternatives) =>
      ResolvedInterval(
        signal: signal.name,
        start: start,
        end: end,
        kind: 'gap',
        winner: null,
        alternatives: alternatives,
        agreement: 'none',
        reasonCode: code,
        reason: reason,
        values: const {},
      );

  List<String> ranked(Iterable<String> ids) {
    final list = ids.toList();
    int rank(String id) {
      final i = run.order.indexOf(id);
      return i < 0 ? run.order.length : i;
    }

    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.compareTo(b);
    });
    return list;
  }

  if (covering.isEmpty) {
    return thin
        ? gap('thinData',
            'Recorded for under $_minutes minutes, which is too short to use.',
            const [])
        : gap('noCoverage', 'No source recorded here.', const []);
  }
  if (owner == null) {
    return gap(
      'noCoverage',
      'None of the sources that recorded here is in your order, so none is used.',
      ranked(covering),
    );
  }
  if (!covering.contains(owner)) {
    return gap(
      'noCoverage',
      'The source that owns this stretch recorded nothing here, and a handover '
      'needs $_minutes minutes from another source.',
      ranked(covering),
    );
  }
  final alternatives = ranked(covering.where((id) => id != owner));
  final single = alternatives.isEmpty;
  final (code, reason) = single
      ? ('onlySource', 'Only one source recorded here.')
      : run.isDefault
          ? ('defaultPrimary', 'No order is set, so the band is used.')
          : (
              'userPriority',
              'Ranked first in your order among the sources recording here.',
            );
  return ResolvedInterval(
    signal: signal.name,
    start: start,
    end: end,
    kind: single ? 'single' : 'overlap',
    winner: owner,
    alternatives: alternatives,
    agreement: single ? 'single' : 'none',
    reasonCode: code,
    reason: reason,
    values: const {},
  );
}

bool _sameRow(ResolvedInterval a, ResolvedInterval b) =>
    a.end == b.start &&
    a.kind == b.kind &&
    a.winner == b.winner &&
    a.reasonCode == b.reasonCode &&
    a.reason == b.reason &&
    _sameList(a.alternatives, b.alternatives);

ResolvedInterval _withEnd(ResolvedInterval r, int end) => ResolvedInterval(
      signal: r.signal,
      start: r.start,
      end: end,
      kind: r.kind,
      winner: r.winner,
      alternatives: r.alternatives,
      agreement: r.agreement,
      reasonCode: r.reasonCode,
      reason: r.reason,
      values: r.values,
    );

// ponytail: one AVG query per contested stretch. A flapping pair could make
// that many; batch by window if a real capture shows hundreds.
Future<ResolvedInterval> _withAgreement(ResolvedInterval r) async {
  final means = await LocalDb.meanHrByDevice(r.start, r.end);
  final values = {
    for (final id in [r.winner!, ...r.alternatives])
      if (means[id] != null) id: means[id]!,
  };
  final spread = values.length < 2
      ? null
      : values.values.reduce((a, b) => a > b ? a : b) -
          values.values.reduce((a, b) => a < b ? a : b);
  return ResolvedInterval(
    signal: r.signal,
    start: r.start,
    end: r.end,
    kind: r.kind,
    winner: r.winner,
    alternatives: r.alternatives,
    agreement: spread == null
        ? 'none'
        : spread <= kAgreementToleranceBpm
            ? 'agree'
            : 'disagree',
    reasonCode: r.reasonCode,
    reason: r.reason,
    values: values,
  );
}
