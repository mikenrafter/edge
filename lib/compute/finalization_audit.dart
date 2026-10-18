// finalization_audit.dart — the pure half of the finalization audit.
//
// A day is derived many times while it is open by accumulator-based paths (the
// cardio row cache, streaming night streams, the day checkpoint), all designed
// to equal the batch path bit for bit. Once, when a day FINALIZES and the power
// policy allows heavy work, the engine re-derives it on the pure batch path and
// compares the two with [auditFinalization]. The engine owns the I/O; this file
// is pure Dart and isolate-safe.

/// The verdict of one audit: the dotted paths where the payloads differ.
class AuditResult {
  const AuditResult({required this.diffKeys});

  /// Sorted, de-duplicated dotted paths.
  final List<String> diffKeys;
  bool get ok => diffKeys.isEmpty;
  int get count => diffKeys.length;
}

/// Deep, exact comparison of two day payloads. `computed_at` (a wall-clock
/// stamp, never a metric) is ignored on both sides. Doubles compare bit for bit
/// (NaN equals NaN, 0.0 differs from -0.0); int 1 and double 1.0 differ. A
/// list of another length is reported once, at the list path.
AuditResult auditFinalization(
  Map<String, dynamic> accumulator,
  Map<String, dynamic> batch,
) {
  final out = <String>{};
  _diffMap('', accumulator, batch, out, top: true);
  return AuditResult(diffKeys: out.toList()..sort());
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

void _diffMap(String path, Map a, Map b, Set<String> out, {bool top = false}) {
  for (final k in {...a.keys, ...b.keys}) {
    if (top && k == 'computed_at') continue;
    final p = _join(path, '$k');
    if (!a.containsKey(k) || !b.containsKey(k)) {
      out.add(p);
    } else {
      _diff(p, a[k], b[k], out);
    }
  }
}

void _diff(String path, Object? a, Object? b, Set<String> out) {
  if (a is Map && b is Map) return _diffMap(path, a, b, out);
  if (a is List && b is List) {
    if (a.length != b.length) {
      out.add(path);
      return;
    }
    for (var i = 0; i < a.length; i++) {
      _diff('$path[$i]', a[i], b[i], out);
    }
    return;
  }
  final same = switch ((a, b)) {
    (double x, double y) => x.compareTo(y) == 0,
    (int x, int y) => x == y,
    (num _, num _) => false, // int against double
    _ => a == b && a.runtimeType == b.runtimeType,
  };
  if (!same) out.add(path);
}

/// `[audit] <day> ok` or `[audit] <day> diff <n> keys: <k1>, ...` (first 5).
String auditLogLine(String day, AuditResult r) => r.ok
    ? '[audit] $day ok'
    : '[audit] $day diff ${r.count} keys: ${r.diffKeys.take(5).join(', ')}';

/// The persistent audit counter, one `last_result` row (`audit|state`).
class FinalizationAuditState {
  FinalizationAuditState({
    this.runs = 0,
    this.diffs = 0,
    List<String>? pending,
    this.lastDiffDay,
    List<String>? lastDiffKeys,
  })  : pending = pending ?? <String>[],
        lastDiffKeys = lastDiffKeys ?? <String>[];

  /// Completed audits, timely or late.
  int runs;

  /// Audits that found at least one differing key.
  int diffs;

  /// Sorted ids of finalized days still awaiting an audit.
  List<String> pending;
  String? lastDiffDay;
  List<String> lastDiffKeys;

  Map<String, dynamic> toJson() => {
        'runs': runs,
        'diffs': diffs,
        'pending': pending,
        'last_diff_day': lastDiffDay,
        'last_diff_keys': lastDiffKeys,
      };

  factory FinalizationAuditState.fromJson(Map<String, dynamic> j) =>
      FinalizationAuditState(
        runs: (j['runs'] as num?)?.toInt() ?? 0,
        diffs: (j['diffs'] as num?)?.toInt() ?? 0,
        pending: [for (final d in (j['pending'] as List?) ?? const []) '$d'],
        lastDiffDay: j['last_diff_day'] as String?,
        lastDiffKeys: [
          for (final d in (j['last_diff_keys'] as List?) ?? const []) '$d'
        ],
      );
}
