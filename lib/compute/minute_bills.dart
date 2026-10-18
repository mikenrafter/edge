import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'resume_bytes.dart';

/// One minute's price as `IncrementalMinuteMetrics` holds it.
class MinuteBill {
  const MinuteBill({
    required this.key,
    required this.hr,
    required this.cadence,
    required this.trimp,
    required this.source,
    required this.active,
    required this.walking,
  });

  final int key;
  final double hr;
  final double? cadence;
  final double trimp;
  final String? source;
  final double active, walking;
}

/// The priced minutes of a day's wake series and the anchors they were priced
/// under, so a state resumed from storage can carry on from them: the minute
/// calculation compares each minute's HR and cadence, and the anchors, with
/// what it holds, and prices only what differs.
///
/// Read-only copy of a state the analytics package owns, taken through its own
/// `toJson` and handed back through its `fromJson`, which re-checks it. The
/// bills are not part of the folded day: they depend on the anchors, so they are
/// a cache, and a blob without them (or with ones that do not load) costs one
/// repricing and nothing else.
class MinuteBills {
  const MinuteBills({
    required this.restingHr,
    required this.maxHr,
    required this.sex,
    required this.profile,
    required this.basalPerMinute,
    required this.bills,
  });

  final double? restingHr, maxHr;
  final String sex;

  /// `[weightKg, heightCm, age, sex]` of the calorie profile, or null.
  final ({double weightKg, double heightCm, double age, String sex})? profile;
  final double? basalPerMinute;

  /// Ascending by [MinuteBill.key].
  final List<MinuteBill> bills;

  /// The bills of [json] (`IncrementalMinuteMetrics.toJson()`) for minutes
  /// before [beforeMinute], or null when it holds nothing worth keeping or
  /// something that does not round-trip (a non-finite number).
  static MinuteBills? fromMetricsJson(
    Map<String, dynamic> json, {
    required int beforeMinute,
  }) {
    final params = json['parameters'];
    if (params is! List || params.length != 4) return null;
    final p = params[3];
    ({double weightKg, double heightCm, double age, String sex})? profile;
    if (p != null) {
      if (p is! List ||
          p.length != 4 ||
          p[0] is! double ||
          p[1] is! double ||
          p[2] is! double ||
          p[3] is! String) {
        return null;
      }
      profile = (weightKg: p[0], heightCm: p[1], age: p[2], sex: p[3]);
    }
    if ((params[0] != null && params[0] is! double) ||
        (params[1] != null && params[1] is! double) ||
        params[2] is! String) {
      return null;
    }
    final basal = json['basalPerMinute'];
    if (basal != null && basal is! double) return null;
    final bills = <MinuteBill>[];
    for (final raw in json['bills'] as List) {
      final b = raw as Map<String, dynamic>;
      final key = b['key'];
      if (key is! int || key >= beforeMinute) continue;
      if (b['hr'] is! double ||
          (b['cadence'] != null && b['cadence'] is! double) ||
          b['trimp'] is! double ||
          b['active'] is! double ||
          b['walking'] is! double) {
        return null;
      }
      bills.add(MinuteBill(
        key: key,
        hr: b['hr'] as double,
        cadence: b['cadence'] as double?,
        trimp: b['trimp'] as double,
        source: b['source'] as String?,
        active: b['active'] as double,
        walking: b['walking'] as double,
      ));
    }
    if (bills.isEmpty) return null;
    bills.sort((a, b) => a.key.compareTo(b.key));
    return MinuteBills(
      restingHr: params[0] as double?,
      maxHr: params[1] as double?,
      sex: params[2] as String,
      profile: profile,
      basalPerMinute: basal as double?,
      bills: bills,
    );
  }

  /// A `IncrementalMinuteMetrics.fromJson` document for these bills. Throws
  /// [FormatException] when the package finds them inconsistent.
  Map<String, dynamic> toMetricsJson() {
    var trimp = 0.0, active = 0.0, walking = 0.0;
    for (final b in bills) {
      trimp += b.trimp;
      active += b.active;
      walking += b.walking;
    }
    return {
      'version': 1,
      'type': 'IncrementalMinuteMetrics',
      // What this state was read back with, not work done since: callers report
      // the difference.
      'processedMinutes': bills.length,
      'parameters': [
        restingHr,
        maxHr,
        sex,
        profile == null
            ? null
            : [profile!.weightKg, profile!.heightCm, profile!.age, profile!.sex],
      ],
      'trimpTotal': trimp,
      'hrActiveTotal': active,
      'walkingTotal': walking,
      'basalPerMinute': basalPerMinute,
      'bills': [
        for (final b in bills)
          {
            'key': b.key,
            'hr': b.hr,
            'cadence': b.cadence,
            'trimp': b.trimp,
            'source': b.source,
            'active': b.active,
            'walking': b.walking,
          },
      ],
    };
  }

  /// The metrics object these bills describe, or null if the package refuses
  /// them.
  ana.IncrementalMinuteMetrics? toMetrics() {
    try {
      return ana.IncrementalMinuteMetrics.fromJson(toMetricsJson());
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  void write(ResumeWriter w) {
    w.optF64(restingHr);
    w.optF64(maxHr);
    _str(w, sex);
    w.bool_(profile != null);
    if (profile != null) {
      w.f64(profile!.weightKg);
      w.f64(profile!.heightCm);
      w.f64(profile!.age);
      _str(w, profile!.sex);
    }
    w.optF64(basalPerMinute);
    final names = <String>{
      for (final b in bills)
        if (b.source != null) b.source!,
    }.toList();
    w.u8(names.length);
    for (final n in names) {
      _str(w, n);
    }
    w.i32(bills.length);
    for (final b in bills) {
      w.i64(b.key);
      w.f64(b.hr);
      w.optF64(b.cadence);
      w.f64(b.trimp);
      w.u8(b.source == null ? 0 : names.indexOf(b.source!) + 1);
      w.f64(b.active);
      w.f64(b.walking);
    }
  }

  static MinuteBills read(ResumeReader r) {
    final rhr = r.optF64(), maxHr = r.optF64();
    final sex = _readStr(r);
    ({double weightKg, double heightCm, double age, String sex})? profile;
    if (r.bool_()) {
      profile = (
        weightKg: r.f64(),
        heightCm: r.f64(),
        age: r.f64(),
        sex: _readStr(r),
      );
    }
    final basal = r.optF64();
    final names = [for (var i = r.u8(); i > 0; i--) _readStr(r)];
    final n = r.count(35);
    final bills = <MinuteBill>[];
    for (var i = 0; i < n; i++) {
      final key = r.i64();
      final hr = r.f64();
      final cadence = r.optF64();
      final trimp = r.f64();
      final s = r.u8();
      if (s > names.length) throw const FormatException('resume state: bad source');
      bills.add(MinuteBill(
        key: key,
        hr: hr,
        cadence: cadence,
        trimp: trimp,
        source: s == 0 ? null : names[s - 1],
        active: r.f64(),
        walking: r.f64(),
      ));
    }
    return MinuteBills(
      restingHr: rhr,
      maxHr: maxHr,
      sex: sex,
      profile: profile,
      basalPerMinute: basal,
      bills: bills,
    );
  }

  static void _str(ResumeWriter w, String s) {
    final b = utf8.encode(s);
    w.u8(b.length);
    w.bytes(Uint8List.fromList(b), b.length);
  }

  static String _readStr(ResumeReader r) {
    final n = r.u8();
    return utf8.decode(r.bytes(n));
  }
}
