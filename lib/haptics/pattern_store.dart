// 8AD: the named pattern store.
//
// A saved pattern is a BuzzSequence with a name and a stable id. A rule that
// picked one holds a SNAPSHOT of it with BuzzSequence.patternId set, so
// delivery never looks the store up. Editing or deleting a stored pattern goes
// through [propagatePattern], which rewrites the snapshots in every place a
// sequence is stored: the alert rules of NotificationPrefs, and the relay's
// ChannelConfig.buzzSequence and ChannelConfig.appSequences. A new field
// holding a BuzzSequence must be added there (AGENTS.md 4.7). The edit and the
// propagation are ONE SettingsRepository.update (SettingsDraft.propagatePattern).

import 'dart:convert';
import 'dart:math';

import '../notify/alert_rule.dart';
import '../notify/buzz_sequence.dart';
import '../notify/notification_prefs.dart';
import '../notify/notification_relay.dart';
import '../settings/settings_repository.dart';

const int kPatternNameMax = 40;

/// The trimmed [name], or an ArgumentError when it is empty or over
/// [kPatternNameMax] characters.
String _checkedName(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > kPatternNameMax) {
    throw ArgumentError.value(
      name,
      'name',
      'A pattern name is 1-$kPatternNameMax characters',
    );
  }
  return n;
}

class SavedHapticPattern {
  SavedHapticPattern({
    required this.id,
    required String name,
    required this.sequence,
  }) : name = _checkedName(name) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
  }

  final String id;
  final String name;
  final BuzzSequence sequence;

  Object toJson() => {'id': id, 'name': name, 'sequence': sequence.toJson()};

  factory SavedHapticPattern.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('A saved pattern is a map');
    }
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) {
      throw const FormatException('A saved pattern needs an id and a name');
    }
    if (json['sequence'] == null) {
      throw const FormatException('A saved pattern needs a sequence');
    }
    try {
      return SavedHapticPattern(
        id: id,
        name: name,
        sequence: BuzzSequence.fromJson(json['sequence']),
      );
    } on ArgumentError catch (e) {
      throw FormatException('Invalid saved pattern: ${e.message}');
    }
  }
}

class HapticPatternStore {
  HapticPatternStore._(Iterable<SavedHapticPattern> patterns)
    : _patterns = {for (final p in patterns) p.id: p};

  static const String prefsKey = 'haptic_patterns_v1';

  final Map<String, SavedHapticPattern> _patterns;

  /// The stored patterns. Unreadable data never throws: it gives an empty
  /// store, or drops the entries that do not read.
  /// A thin wrapper over the settings repository.
  static Future<HapticPatternStore> load() =>
      SettingsRepository.instance.patterns();

  /// The store a stored string reads as ([raw] is the value under [prefsKey],
  /// or null). Never throws; entries that do not read are dropped.
  factory HapticPatternStore.decode(String? raw) {
    final good = <SavedHapticPattern>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final names = <String>{};
          final ids = <String>{};
          for (final e in decoded) {
            try {
              final p = SavedHapticPattern.fromJson(e);
              if (ids.add(p.id) && names.add(p.name.toLowerCase())) good.add(p);
            } on FormatException {
              // A bad entry is dropped; the good ones stay.
            }
          }
        }
      } on FormatException {
        // Not JSON: an empty store.
      }
    }
    return HapticPatternStore._(good);
  }

  /// The string stored under [prefsKey].
  String encode() => jsonEncode([for (final p in list) p.toJson()]);

  /// An independent copy: editing one does not change the other.
  HapticPatternStore copy() => HapticPatternStore._(_patterns.values);

  /// Writes the store. A thin wrapper over the settings repository: an edit
  /// that also rewrites the alert rules or relay channels (propagatePattern)
  /// belongs in one [SettingsRepository.update], not here.
  Future<void> save() => SettingsRepository.instance
      .update((d) => d.patterns = this, sections: {SettingsSection.patterns})
      .then<void>((_) {});

  /// Ordered by name, ignoring case (ties by name as written).
  List<SavedHapticPattern> get list =>
      _patterns.values.toList()..sort((a, b) {
        final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return c != 0 ? c : a.name.compareTo(b.name);
      });

  SavedHapticPattern? byId(String id) => _patterns[id];

  bool _taken(String name, {String? except}) => _patterns.values.any(
    (p) => p.id != except && p.name.toLowerCase() == name.toLowerCase(),
  );

  SavedHapticPattern _existing(String id) =>
      _patterns[id] ?? (throw ArgumentError.value(id, 'id', 'unknown pattern'));

  static final Random _rng = Random.secure();

  static String _newId() => [
    for (var i = 0; i < 4; i++)
      _rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
  ].join();

  /// A new pattern; its sequence carries its patternId.
  SavedHapticPattern add(String name, BuzzSequence sequence) {
    final n = _checkedName(name);
    if (_taken(n)) {
      throw ArgumentError.value(name, 'name', 'That name is already used');
    }
    var id = _newId();
    while (_patterns.containsKey(id)) {
      id = _newId();
    }
    final p = SavedHapticPattern(
      id: id,
      name: n,
      sequence: sequence.copyWith(patternId: id),
    );
    _patterns[id] = p;
    return p;
  }

  void rename(String id, String name) {
    final old = _existing(id);
    final n = _checkedName(name);
    if (_taken(n, except: id)) {
      throw ArgumentError.value(name, 'name', 'That name is already used');
    }
    _patterns[id] = SavedHapticPattern(
      id: id,
      name: n,
      sequence: old.sequence,
    );
  }

  void replace(String id, BuzzSequence sequence) {
    final old = _existing(id);
    _patterns[id] = SavedHapticPattern(
      id: id,
      name: old.name,
      sequence: sequence.copyWith(patternId: id),
    );
  }

  void delete(String id) {
    _existing(id);
    _patterns.remove(id);
  }
}

/// The prefs and relay channels after a stored pattern changed.
class PatternPropagation {
  const PatternPropagation({required this.prefs, required this.channels});
  final NotificationPrefs prefs;
  final Map<String, ChannelConfig> channels;
}

/// Rewrites every snapshot of pattern [patternId]. With a [replacement] each
/// becomes that sequence (stamped with the id); without one (the pattern was
/// deleted) each keeps its rhythm and loses the id. The inputs are not
/// changed.
PatternPropagation propagatePattern(
  String patternId, {
  required NotificationPrefs prefs,
  required Map<String, ChannelConfig> channels,
  BuzzSequence? replacement,
}) {
  BuzzSequence rewrite(BuzzSequence s) => replacement == null
      ? s.copyWith(clearPatternId: true)
      : replacement.copyWith(patternId: patternId);
  bool holds(BuzzSequence? s) => s != null && s.patternId == patternId;

  // Place 1: the alert rules.
  final rules = <String, AlertRule>{
    for (final e in prefs.alertRules.entries)
      if (holds(e.value.buzzSequence))
        e.key: e.value.copyWith(buzzSequence: rewrite(e.value.buzzSequence!)),
  };

  // Places 2 and 3: each channel's own sequence and its per-app sequences.
  final out = <String, ChannelConfig>{};
  for (final e in channels.entries) {
    final c = e.value;
    out[e.key] = c.copyWith(
      buzzSequence: holds(c.buzzSequence) ? rewrite(c.buzzSequence!) : null,
      appSequences: c.appSequences.values.any(holds)
          ? {
              for (final a in c.appSequences.entries)
                a.key: holds(a.value) ? rewrite(a.value) : a.value,
            }
          : null,
    );
  }
  return PatternPropagation(
    prefs: rules.isEmpty ? prefs : prefs.copyWith(alertRules: rules),
    channels: out,
  );
}

/// How many places hold a snapshot of [patternId]: one per alert rule, per
/// channel sequence and per app sequence.
int patternUsageCount(
  String patternId, {
  required NotificationPrefs prefs,
  required Map<String, ChannelConfig> channels,
}) {
  var n = 0;
  for (final r in prefs.alertRules.values) {
    if (r.buzzSequence?.patternId == patternId) n++;
  }
  for (final c in channels.values) {
    if (c.buzzSequence?.patternId == patternId) n++;
    for (final s in c.appSequences.values) {
      if (s.patternId == patternId) n++;
    }
  }
  return n;
}
