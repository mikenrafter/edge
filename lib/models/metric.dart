// Metric — the canonical {value, unit, confidence, tier, label, inputs_used}
// shape every backend metric returns (see CONFIDENCE.md §6). Parsed defensively:
// the backend is finalized in parallel, so any field may be missing.

/// Confidence/honesty tier from CONFIDENCE.md.
enum MetricTier { authoritative, high, estimate, relative, unknown }

MetricTier _tierFrom(Object? raw) {
  switch (raw?.toString().toUpperCase()) {
    // 'AUTH' is the string the analytics package actually emits
    // (`Tier.auth` in lib/src/onehz/types.dart) — 'AUTHORITATIVE' was our own
    // invention and matched nothing. Until this line, every user-stated fact
    // (the manual sleep override at derivation_engine.dart writes
    // `tier: ana.Tier.auth`) parsed to MetricTier.unknown and lost its tier on
    // the way to the screen. Both spellings are accepted so old stored
    // day_result rows keep parsing.
    case 'AUTH':
    case 'AUTHORITATIVE':
      return MetricTier.authoritative;
    case 'HIGH':
      return MetricTier.high;
    case 'ESTIMATE':
      return MetricTier.estimate;
    case 'RELATIVE':
      return MetricTier.relative;
    default:
      return MetricTier.unknown;
  }
}

class Metric {
  final num? value;
  final String? unit;
  final double confidence; // 0..1
  final MetricTier tier;
  final String? label;
  final List<String> inputsUsed;
  final bool beta;

  /// Optional honesty / machine-readable note from the metric envelope. Carries
  /// the `need_baseline:have=H,need=N` convention for baseline-gated abstentions
  /// so the UI can render "Need N more nights" instead of a bare "—".
  final String? note;

  const Metric({
    this.value,
    this.unit,
    this.confidence = 0,
    this.tier = MetricTier.unknown,
    this.label,
    this.inputsUsed = const [],
    this.beta = false,
    this.note,
  });

  /// Parsed `need_baseline:have=H,need=N` → remaining nights (need − have, ≥1),
  /// or null when this metric is not a baseline-gated abstention. Drives the
  /// "Need N more nights" copy.
  int? get needMoreNights => needMoreNightsFromNote(note);

  /// A metric with no real data — renders as "—".
  static const empty = Metric();

  /// True when there's no number to show. CONFIDENCE rule #1.
  bool get isEmpty => value == null || confidence <= 0;

  bool get isEstimate => tier == MetricTier.estimate;
  bool get isRelative => tier == MetricTier.relative;

  /// Normalized 0..1 for ring color, given a max scale (e.g. 21 for strain,
  /// 100 for readiness). Clamped.
  double normalized(num max) {
    final v = value;
    if (v == null || max == 0) return double.nan;
    return (v / max).clamp(0.0, 1.0).toDouble();
  }

  /// Parse from a metric object OR from a bare scalar with an external `flags`
  /// entry ({c, tier, label}) — daily/sleep rows carry per-metric flags.
  factory Metric.parse(Object? raw, {Map<String, dynamic>? flag}) {
    // Case A: the metric is itself an object.
    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      return Metric(
        value: _num(m['value']),
        unit: m['unit']?.toString(),
        confidence: _dbl(m['confidence']),
        tier: _tierFrom(m['tier']),
        label: m['label']?.toString(),
        inputsUsed: _list(m['inputs_used']),
        beta: _bool(m['beta']) || _tierFrom(m['tier']) == MetricTier.estimate,
        note: m['note']?.toString(),
      );
    }
    // Case B: a scalar value + a separate flags entry {c, tier, label, beta}.
    final f = flag ?? const {};
    final tier = _tierFrom(f['tier']);
    return Metric(
      value: _num(raw),
      unit: f['unit']?.toString(),
      confidence: f.containsKey('c')
          ? _dbl(f['c'])
          : (raw == null ? 0.0 : 1.0), // bare value with no flag → assume known
      tier: tier,
      label: f['label']?.toString(),
      inputsUsed: _list(f['inputs_used']),
      beta: _bool(f['beta']) || _bool(f['x']) || tier == MetricTier.estimate,
    );
  }

  static num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  static double _dbl(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static bool _bool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

  static List<String> _list(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }
}

/// Parse the analytics `need_baseline:have=H,need=N` note convention into the
/// number of additional nights still required (need − have, floored at 1), or
/// null if [note] isn't a need_baseline note. Lets any screen turn a baseline-
/// gated abstention into "Need N more nights" copy.
int? needMoreNightsFromNote(String? note) {
  if (note == null || !note.contains('need_baseline:')) return null;
  final m = RegExp(r'have=(\d+),need=(\d+)').firstMatch(note);
  if (m == null) return null;
  final have = int.tryParse(m.group(1)!);
  final need = int.tryParse(m.group(2)!);
  if (have == null || need == null) return null;
  final remaining = need - have;
  return remaining < 1 ? 1 : remaining;
}

/// The two numbers behind the same note — nights banked and nights needed.
///
/// A baseline gate is the only absence that is PROGRESS rather than a gap, so
/// it is the only one a ring can honestly draw: an arc at have/need is going
/// somewhere, where an arc at zero would be a low score. Null for every other
/// note, which is what keeps that arc off an absence that is not progress.
({int have, int need})? baselineCountsFromNote(String? note) {
  if (note == null || !note.contains('need_baseline:')) return null;
  final m = RegExp(r'have=(\d+),need=(\d+)').firstMatch(note);
  if (m == null) return null;
  final have = int.tryParse(m.group(1)!);
  final need = int.tryParse(m.group(2)!);
  if (have == null || need == null || need <= 0) return null;
  return (have: have, need: need);
}

/// A natural-language "need more data" message from a need_baseline note.
/// [unit] picks the wording: 'nights' (sleep/recovery/HRV-baseline metrics) →
/// "Need N more nights"; 'days' (activity/fitness) → "Wear N more days to
/// unlock". Returns null when [note] isn't a need_baseline note.
String? needMessageFromNote(String? note, {String unit = 'nights'}) {
  final n = needMoreNightsFromNote(note);
  if (n == null) return null;
  if (unit == 'days') {
    return 'Wear $n more day${n == 1 ? '' : 's'} to unlock';
  }
  return 'Need $n more night${n == 1 ? '' : 's'}';
}

/// Machine-readable note token — `key:arg`, no space after the colon. The
/// pipeline's prose notes ('refused: the red and IR channels …') keep theirs,
/// which is what tells the two apart.
final _machineNote = RegExp(r'^[a-z][a-z0-9_]*:\S');

final _noteCounts = RegExp(r'have=(\d+),need=(\d+)');
final _noteInput = RegExp(r'name=([a-z0-9_]+)');

/// `need_input:name=X` → the missing INPUT, named in words the user can act on.
/// The input, never the metric that wanted it: "calories" is not something
/// anyone can go and fix, "your weight" is. A name with no sentence here falls
/// through to null and the card says it does not know — which is correct, and
/// is the only safe default for a key added after this map was written.
const _inputWhy = {
  'age': 'This metric needs your age, which is not on file.',
  'weight_kg': 'This metric needs your weight, which is not on file.',
  'height_cm': 'This metric needs your height, which is not on file.',
  'sex': 'This metric needs your sex, which is not on file.',
  'wake_hr': 'No waking heart rate was recorded for this day.',
  'hr_samples': 'Not enough heart-rate samples to calculate this.',
  'resting_hr':
      'No scored night gives a resting heart rate to compare against.',
  'scored_night': 'This metric needs a scored night, and there is none.',
  'nn_beats': 'Not enough clean beat-to-beat intervals to calculate this.',
  'resp_windows':
      'Not enough half-hour stretches of clean breathing '
      'overnight to compare.',
  'accel_1hz': 'The band recorded heart rate but no motion data.',
  // NOT a wait-and-it-fills absence: an imported day has no raw behind it to
  // re-derive from, so the copy must not imply that wearing the band will
  // backfill it. 284 of whoop-5's 287 days are this.
  'imported_day':
      'This day comes from an imported export, which holds the night only. '
      'The app has no waking-day data and no raw records to compute it from.',
  'today_activity':
      'No activity data has reached the app for today yet.',
  'tst_min': 'That night has no total sleep time recorded.',
  'wake_time': 'That night has no wake time recorded.',
  'efficiency': 'That night has no sleep efficiency recorded.',
  'observed_ceiling':
      'Your heart rate has not yet stayed high enough during a hard effort '
      'to measure your maximum.',
  // DISTINCT from `observed_ceiling`, and the distinction is the whole point:
  // there IS a held ceiling, it is on the screen with its date, and the card
  // would otherwise ask for the thing it is simultaneously showing.
  'maximal_effort':
      'Your highest recorded heart rate is well below the age-based estimate, '
      'so the app treats it as a submaximal effort. '
      'Zones use the age estimate until the band records a harder effort.',
  'resting_hr_days':
      'Heart rate reserve needs more nights of resting heart rate.',
  'manual_zones':
      'You set your zones manually, so there is no heart rate reserve '
      'to plot a distribution against.',
  'sessions':
      'Too few recorded sessions to show a pattern.',
};

/// THE REASON THE DATA GAVE, as a sentence — or null when nothing said why.
///
/// A screen may only state a cause it was handed. Notes arrive in two shapes:
/// `key:arg` is machine-readable and gets its sentence written here, and
/// everything else the pipeline emits is already prose and passes through. A
/// machine token nobody has written a sentence for returns NULL rather than
/// being printed raw or paraphrased — the caller then says it does not know,
/// which is the whole point. Inventing a plausible cause is the defect this
/// exists to stop: a false diagnosis with an unactionable fix costs more trust
/// than a bare absence, because the user does the thing and nothing happens.
String? whyFromNote(String? note, {String unit = 'nights'}) {
  final s = note?.trim() ?? '';
  if (s.isEmpty) return null;
  final need = needMessageFromNote(s, unit: unit);
  if (need != null) return need;
  if (s.startsWith('need_input:')) {
    final why = _inputWhy[_noteInput.firstMatch(s)?.group(1)];
    if (why == null) return null;
    final c = _noteCounts.firstMatch(s);
    return c == null ? why : '$why The app has ${c[1]} and needs ${c[2]}.';
  }
  if (s.startsWith('unknown_device_family')) {
    return 'These recordings do not say which strap made them. '
           'This number needs a per-strap calibration, so the app withholds it.';
  }
  // The pipeline's own "we could not attribute this" marker. It exists so an
  // absence never has to borrow a plausible reason, so it renders as no reason.
  if (s == 'unknown_cause') return null;
  return _machineNote.hasMatch(s) ? null : s;
}

/// Pull a per-metric flag map ({c, tier, label, beta}) out of a row's `flags`
/// blob, which may be a JSON string or an already-decoded map.
Map<String, dynamic>? flagFor(Object? flags, String key) {
  if (flags is Map) {
    final v = flags[key];
    if (v is Map) return v.cast<String, dynamic>();
  }
  return null;
}
