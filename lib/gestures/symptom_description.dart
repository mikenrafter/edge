// symptom_description.dart — the structured "Symptom" answer of a marked moment.
//
// Answering Symptom opens a describer: severity, an optional side, a kind and a
// body area. It is rendered "<severity> <kind> in my <area> (<side>)" (the
// side in parentheses after the area, omitted when unset, so a side never has
// to agree with the area's number), stored structured (never as that string),
// and shown in the journal and as the moment's label. NOTHING is derived from
// it: no score, no metric, no correlation input.

import '../l10n/app_localizations.dart';

/// In the order the describer offers them.
enum SymptomSeverity {
  severe,
  moderate,
  mild,
  faint;

  /// Persisted id (stable, lowercase).
  String get id => name;
  String localized(AppLocalizations? l) => switch (this) {
        severe => l?.symptomSeveritySevere ?? 'severe',
        moderate => l?.symptomSeverityModerate ?? 'moderate',
        mild => l?.symptomSeverityMild ?? 'mild',
        faint => l?.symptomSeverityFaint ?? 'faint',
      };
}

enum SymptomSide {
  left,
  right,
  both,
  center,
  all;

  String get id => name;
  String localized(AppLocalizations? l) => switch (this) {
        left => l?.symptomSideLeft ?? 'left',
        right => l?.symptomSideRight ?? 'right',
        both => l?.symptomSideBoth ?? 'both',
        center => l?.symptomSideCenter ?? 'center',
        all => l?.symptomSideAll ?? 'all',
      };
}

enum SymptomKind {
  pain,
  swelling,
  itchiness,
  irritation,
  numbness,
  soreness,
  tingling,

  /// Free text ([SymptomDescription.kindOther]).
  other;

  String get id => name;
  String localized(AppLocalizations? l) => switch (this) {
        pain => l?.symptomKindPain ?? 'pain',
        swelling => l?.symptomKindSwelling ?? 'swelling',
        itchiness => l?.symptomKindItchiness ?? 'itchiness',
        irritation => l?.symptomKindIrritation ?? 'irritation',
        numbness => l?.symptomKindNumbness ?? 'numbness',
        soreness => l?.symptomKindSoreness ?? 'soreness',
        tingling => l?.symptomKindTingling ?? 'tingling',
        other => l?.symptomKindOther ?? 'other',
      };
}

/// Body order, low to high.
enum SymptomArea {
  feet,
  ankles,
  calves,
  knees,
  thighs,
  hips,
  glutes,
  lowerAbdomen,
  lowerBack,
  upperAbdomen,
  midBack,
  chest,
  upperBack,
  shoulders,
  arms,
  elbows,
  wrists,
  hands,
  neck,
  jaw,
  face,
  forehead,
  skull,

  /// Free text ([SymptomDescription.areaOther]).
  other;

  /// snake_case of the member name (`lowerBack` -> `lower_back`): persisted.
  String get id => name.replaceAllMapped(
      RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
  String localized(AppLocalizations? l) => switch (this) {
        feet => l?.symptomAreaFeet ?? 'feet',
        ankles => l?.symptomAreaAnkles ?? 'ankles',
        calves => l?.symptomAreaCalves ?? 'calves',
        knees => l?.symptomAreaKnees ?? 'knees',
        thighs => l?.symptomAreaThighs ?? 'thighs',
        hips => l?.symptomAreaHips ?? 'hips',
        glutes => l?.symptomAreaGlutes ?? 'glutes',
        lowerAbdomen => l?.symptomAreaLowerAbdomen ?? 'lower abdomen',
        lowerBack => l?.symptomAreaLowerBack ?? 'lower back',
        upperAbdomen => l?.symptomAreaUpperAbdomen ?? 'upper abdomen',
        midBack => l?.symptomAreaMidBack ?? 'mid back',
        chest => l?.symptomAreaChest ?? 'chest',
        upperBack => l?.symptomAreaUpperBack ?? 'upper back',
        shoulders => l?.symptomAreaShoulders ?? 'shoulders',
        arms => l?.symptomAreaArms ?? 'arms',
        elbows => l?.symptomAreaElbows ?? 'elbows',
        wrists => l?.symptomAreaWrists ?? 'wrists',
        hands => l?.symptomAreaHands ?? 'hands',
        neck => l?.symptomAreaNeck ?? 'neck',
        jaw => l?.symptomAreaJaw ?? 'jaw',
        face => l?.symptomAreaFace ?? 'face',
        forehead => l?.symptomAreaForehead ?? 'forehead',
        skull => l?.symptomAreaSkull ?? 'skull',
        other => l?.symptomAreaOther ?? 'other',
      };
}

class SymptomDescription {
  const SymptomDescription({
    required this.severity,
    this.side,
    required this.kind,
    this.kindOther,
    required this.area,
    this.areaOther,
    this.note,
  });

  final SymptomSeverity severity;

  /// Null = not said (the side is left out of the rendering).
  final SymptomSide? side;
  final SymptomKind kind;

  /// Required text when [kind] is [SymptomKind.other].
  final String? kindOther;
  final SymptomArea area;

  /// Required text when [area] is [SymptomArea.other].
  final String? areaOther;

  /// Optional extra free text.
  final String? note;

  /// RED stub: JSON for a review draft (enum ids + typed text; absent = null).
  Map<String, Object?> toJson() => throw UnimplementedError('RED stub');

  /// RED stub: null when [j] is malformed (unknown id, missing part).
  static SymptomDescription? fromJson(Object? j) =>
      throw UnimplementedError('RED stub');

  /// RED stub: value equality over every field.
  @override
  bool operator ==(Object other) => throw UnimplementedError('RED stub');

  @override
  int get hashCode => throw UnimplementedError('RED stub');

  /// `severity kind in my area (side)` (the parenthesis left out when no side
  /// was said); English when [l] is null. Free text is trimmed.
  String describe(AppLocalizations? l) {
    String pick(String? typed, String preset) {
      final t = typed?.trim();
      return t == null || t.isEmpty ? preset : t;
    }

    final sev = severity.localized(l);
    final k = kind == SymptomKind.other
        ? pick(kindOther, kind.localized(l))
        : kind.localized(l);
    final a = area == SymptomArea.other
        ? pick(areaOther, area.localized(l))
        : area.localized(l);
    final sd = side;
    if (sd == null) return l?.symptomDescription(sev, k, a) ?? '$sev $k in my $a';
    final sideText = sd.localized(l);
    return l?.symptomDescriptionSided(sev, k, a, sideText) ??
        '$sev $k in my $a ($sideText)';
  }
}

/// A symptom as read back from `symptom_entry`: the moment it belongs to plus
/// what was said.
class StoredSymptom {
  const StoredSymptom({
    required this.date,
    required this.hhmm,
    required this.description,
    this.createdAtMs = 0,
  });

  /// 'YYYY-MM-DD', local — the moment's day.
  final String date;

  /// 'HH:mm', local — the moment's minute.
  final String hhmm;
  final SymptomDescription description;
  final int createdAtMs;

  String get key => '$date $hhmm';
}
