// symptom_description.dart — the structured "Symptom" answer of a marked moment.
//
// Answering Symptom opens a describer: severity, an optional side, a kind and a
// body area. It is rendered "<severity> <kind> in my <side> <area>" (side
// omitted when unset), stored structured (never as that string), and shown in
// the journal and as the moment's label. NOTHING is derived from it: no score,
// no metric, no correlation input.
//
// RED-phase stub: ids, wording and rendering throw until GREEN implements them.

import '../l10n/app_localizations.dart';

/// In the order the describer offers them.
enum SymptomSeverity {
  severe,
  moderate,
  mild,
  faint;

  /// Persisted id (stable, lowercase).
  String get id => throw UnimplementedError('SymptomSeverity.id');
  String localized(AppLocalizations? l) =>
      throw UnimplementedError('SymptomSeverity.localized');
}

enum SymptomSide {
  left,
  right,
  both,
  center,
  all;

  String get id => throw UnimplementedError('SymptomSide.id');
  String localized(AppLocalizations? l) =>
      throw UnimplementedError('SymptomSide.localized');
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

  String get id => throw UnimplementedError('SymptomKind.id');
  String localized(AppLocalizations? l) =>
      throw UnimplementedError('SymptomKind.localized');
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

  String get id => throw UnimplementedError('SymptomArea.id');
  String localized(AppLocalizations? l) =>
      throw UnimplementedError('SymptomArea.localized');
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

  /// `severity kind in my side area` (side left out when unset); English when
  /// [l] is null.
  String describe(AppLocalizations? l) =>
      throw UnimplementedError('SymptomDescription.describe');
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
