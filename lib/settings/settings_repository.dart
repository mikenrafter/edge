// 8AE.5 P2: the one place settings are read and written.
//
// Four sections over SharedPreferences, each still stored under the key and in
// the JSON it always was (nothing migrates):
//   alerts    NotificationPrefs: the versioned rule blob and its legacy mirrors
//   channels  the relay's ChannelConfig per channel, appSequences included
//   patterns  the named haptic patterns (HapticPatternStore)
//   app       plain Prefs keys, written through [SettingsDraft.setBool] and kin
//
// [SettingsRepository.update] is the one write path. It runs one at a time with
// every other read and write here, hands the edit a [SettingsDraft] over the
// sections it declared, encodes everything the edit changed BEFORE writing a
// byte (so an encode that throws persists nothing), writes the keys together
// (a refused write puts back what was already written, and if putting it back
// fails too, the old values are kept in a recovery journal that the next read or
// write replays before it does anything else), then announces a
// [SettingsChange] on [SettingsRepository.changes]. Readers get immutable
// [SettingsSnapshot]s; NotificationPrefs.load/save and HapticPatternStore
// .load/save remain as thin wrappers over this queue (AGENTS.md 4.7: one path,
// not four).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../haptics/pattern_store.dart';
import '../notify/buzz_sequence.dart';
import '../notify/notification_prefs.dart';
import '../notify/notification_relay.dart';

// The top-level function is shadowed by the draft's own method of that name.
const _propagate = propagatePattern;

enum SettingsSection { alerts, channels, patterns }

/// What every section reads as at one moment. Nothing in it changes.
class SettingsSnapshot {
  SettingsSnapshot({
    required this.alerts,
    required Map<String, ChannelConfig> channels,
    required List<SavedHapticPattern> patterns,
  }) : channels = Map.unmodifiable(channels),
       patterns = List.unmodifiable(patterns);

  final NotificationPrefs alerts;

  /// Every relay channel, with its defaults where nothing is stored.
  final Map<String, ChannelConfig> channels;

  /// The stored patterns, ordered by name.
  final List<SavedHapticPattern> patterns;

  /// How many places hold a snapshot of pattern [id] (see patternUsageCount).
  int patternUsage(String id) =>
      patternUsageCount(id, prefs: alerts, channels: channels);
}

/// What one successful update changed. A section that did not change is null
/// (and an unchanged channel is absent), so a listener never re-applies state
/// it already has.
class SettingsChange {
  const SettingsChange({
    this.alerts,
    this.channels,
    this.patterns,
    this.appPrefs = const {},
    this.origin,
  });

  final NotificationPrefs? alerts;

  /// Only the channels whose stored form changed.
  final Map<String, ChannelConfig>? channels;
  final List<SavedHapticPattern>? patterns;

  /// The app-pref keys written, with their values.
  final Map<String, Object> appPrefs;

  /// Whatever the caller passed as `origin`: a listener that made the change
  /// itself can tell and skip it.
  final Object? origin;

  bool get isEmpty =>
      alerts == null &&
      channels == null &&
      patterns == null &&
      appPrefs.isEmpty;
}

/// The working copy an update edits. Only the sections the update declared are
/// there; reaching for another is a StateError, so a section is never changed
/// without having been read in the same queue slot.
class SettingsDraft {
  SettingsDraft._({
    required Set<SettingsSection> sections,
    NotificationPrefs? alerts,
    Map<String, ChannelConfig>? channels,
    HapticPatternStore? patterns,
  }) : _sections = sections,
       _alerts = alerts,
       _channels = channels == null ? null : Map.of(channels),
       _patterns = patterns?.copy();

  final Set<SettingsSection> _sections;
  NotificationPrefs? _alerts;
  Map<String, ChannelConfig>? _channels;
  HapticPatternStore? _patterns;
  bool _patternsAssigned = false;
  final Map<String, Object> _app = {};

  T _need<T>(SettingsSection s, T? v) {
    if (!_sections.contains(s) || v == null) {
      throw StateError('This update did not declare the ${s.name} section');
    }
    return v;
  }

  NotificationPrefs get alerts => _need(SettingsSection.alerts, _alerts);
  set alerts(NotificationPrefs v) {
    _need(SettingsSection.alerts, _alerts);
    _alerts = v;
  }

  /// A mutable copy of the channels: change it in place or assign a new map.
  Map<String, ChannelConfig> get channels =>
      _need(SettingsSection.channels, _channels);
  set channels(Map<String, ChannelConfig> v) {
    _need(SettingsSection.channels, _channels);
    _channels = Map.of(v);
  }

  /// A working copy of the store: add, rename, replace and delete on it.
  HapticPatternStore get patterns =>
      _need(SettingsSection.patterns, _patterns);

  /// Replaces the whole store (written even if it reads the same).
  set patterns(HapticPatternStore v) {
    _need(SettingsSection.patterns, _patterns);
    _patterns = v.copy();
    _patternsAssigned = true;
  }

  /// Rewrites every snapshot of pattern [id] in the alert rules and the relay
  /// channels (see propagatePattern). Needs the alerts and channels sections.
  void propagatePattern(String id, {BuzzSequence? replacement}) {
    final out = _propagate(
      id,
      prefs: alerts,
      channels: channels,
      replacement: replacement,
    );
    _alerts = out.prefs;
    _channels = Map.of(out.channels);
  }

  // App prefs: written with the rest of the update. Reads stay on Prefs, which
  // shares this SharedPreferences instance.
  void setBool(String key, bool value) => _app[key] = value;
  void setInt(String key, int value) => _app[key] = value;
  void setString(String key, String value) => _app[key] = value;
}

class SettingsRepository {
  SettingsRepository._();

  static final SettingsRepository instance = SettingsRepository._();

  static const String channelsKey = 'notif_relay_channels';

  /// The one key that is new with the journal: a JSON map of key to the value
  /// it held before a failed update, written only when putting those values
  /// back failed. The next read or write puts them back and removes it.
  static const String journalKey = 'settings_recovery_journal_v1';

  static Future<void> _tail = Future.value();
  static int _inFlight = 0;

  static Future<T> _serialize<T>(Future<T> Function() action) {
    // With nothing queued, start from a fresh future in the caller's zone. A
    // listener added to an already-completed future runs in the zone that
    // future was made in, so chaining on the last one would hand this action to
    // a zone that may have finished (a test's, say) and never run it.
    final prev = _inFlight == 0 ? Future<void>.value() : _tail;
    _inFlight++;
    final next = prev.then((_) => action());
    _tail = next.then<void>(
      (_) => _inFlight--,
      onError: (Object _, StackTrace s) => _inFlight--,
    );
    return next;
  }

  final StreamController<SettingsChange> _changes =
      StreamController<SettingsChange>.broadcast();

  /// Every update that changed something, after it was written.
  Stream<SettingsChange> get changes => _changes.stream;

  /// The alert prefs alone (what NotificationPrefs.load returns).
  Future<NotificationPrefs> alerts() =>
      _serialize(() async => NotificationPrefs.readFrom(await _prefs()));

  /// The stored patterns as a store to edit (what HapticPatternStore.load
  /// returns). Saving it again goes through [update].
  Future<HapticPatternStore> patterns() => _serialize(
    () async => HapticPatternStore.decodeSeeded(
      (await _prefs()).getString(HapticPatternStore.prefsKey),
    ),
  );

  /// The relay channels alone (see [decodeChannels]).
  Future<Map<String, ChannelConfig>> channels() => _serialize(
    () async => decodeChannels((await _prefs()).getString(channelsKey)),
  );

  /// One stored app-pref bool, or null when nothing (or nothing boolean) is
  /// stored under [key]. Reads in the same queue as every write, so it never
  /// sees half of an update.
  Future<bool?> appBool(String key) => _serialize(() async {
    final v = (await _prefs()).get(key);
    return v is bool ? v : null;
  });

  /// Every section, as one consistent snapshot.
  Future<SettingsSnapshot> read() => _serialize(() async {
    final sp = await _prefs();
    return SettingsSnapshot(
      alerts: await NotificationPrefs.readFrom(sp),
      channels: decodeChannels(sp.getString(channelsKey)),
      patterns: HapticPatternStore.decodeSeeded(
        sp.getString(HapticPatternStore.prefsKey),
      ).list,
    );
  });

  /// The relay channels a stored string reads as: every channel in
  /// [relayChannels], its default where nothing (or nothing readable) is
  /// stored. Never throws.
  static Map<String, ChannelConfig> decodeChannels(String? raw) {
    Map<String, Object?> saved = const {};
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) saved = Map<String, Object?>.from(d);
      } on FormatException {
        // Not JSON: every channel at its default.
      }
    }
    ChannelConfig one(String c) {
      final d = ChannelConfig.forChannel(c);
      final j = saved[c];
      if (j is! Map) return d;
      try {
        return ChannelConfig.fromJson(Map<String, Object?>.from(j), d);
      } on Object {
        return d;
      }
    }

    return {for (final c in relayChannels) c: one(c)};
  }

  static String _encodeChannels(Map<String, ChannelConfig> channels) =>
      jsonEncode({for (final e in channels.entries) e.key: e.value.toJson()});

  /// Applies [edit] to a draft over [sections] and persists what it changed,
  /// all together or not at all. [edit] is synchronous and runs inside the
  /// queue, so a read-modify-write in it cannot lose another update's change.
  /// If [edit] throws, or anything fails to encode, or a write is refused,
  /// nothing is left written and the error is rethrown. [origin] is carried on
  /// the announced [SettingsChange].
  Future<SettingsChange> update(
    void Function(SettingsDraft d) edit, {
    Set<SettingsSection> sections = const {
      SettingsSection.alerts,
      SettingsSection.channels,
      SettingsSection.patterns,
    },
    Object? origin,
  }) => _serialize(() async {
    // A journal that cannot be replayed stops the update: writing on top of
    // half-restored settings would let a later replay undo it.
    final sp = await _prefs(mustReplay: true);
    final baseAlerts = sections.contains(SettingsSection.alerts)
        ? await NotificationPrefs.readFrom(sp)
        : null;
    final baseChannels = sections.contains(SettingsSection.channels)
        ? decodeChannels(sp.getString(channelsKey))
        : null;
    final basePatterns = sections.contains(SettingsSection.patterns)
        ? HapticPatternStore.decodeSeeded(sp.getString(HapticPatternStore.prefsKey))
        : null;
    final draft = SettingsDraft._(
      sections: sections,
      alerts: baseAlerts,
      channels: baseChannels,
      patterns: basePatterns,
    );
    edit(draft);

    // Encode first: anything that throws here has written nothing.
    final writes = <String, Object>{};
    NotificationPrefs? alertsOut;
    Map<String, ChannelConfig>? channelsOut;
    List<SavedHapticPattern>? patternsOut;
    final a = draft._alerts;
    if (a != null && !identical(a, baseAlerts)) {
      writes.addAll(a.storageEntries());
      alertsOut = a;
    }
    final p = draft._patterns;
    if (p != null) {
      final encoded = p.encode();
      if (draft._patternsAssigned || encoded != basePatterns!.encode()) {
        writes[HapticPatternStore.prefsKey] = encoded;
        patternsOut = p.list;
      }
    }
    final c = draft._channels;
    if (c != null) {
      final encoded = _encodeChannels(c);
      if (encoded != _encodeChannels(baseChannels!)) {
        writes[channelsKey] = encoded;
        channelsOut = {
          for (final e in c.entries)
            if (jsonEncode(e.value.toJson()) !=
                (baseChannels[e.key] == null
                    ? null
                    : jsonEncode(baseChannels[e.key]!.toJson())))
              e.key: e.value,
        };
      }
    }
    writes.addAll(draft._app);

    final change = SettingsChange(
      alerts: alertsOut,
      channels: channelsOut,
      patterns: patternsOut,
      appPrefs: Map.unmodifiable(draft._app),
      origin: origin,
    );
    if (writes.isEmpty) return change;
    await _write(sp, writes);
    _changes.add(change);
    return change;
  });

  /// The preferences, after any pending recovery journal has been replayed.
  /// Runs inside the queue, so a replay never overlaps another read or write.
  static Future<SharedPreferences> _prefs({bool mustReplay = false}) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(journalKey);
    if (raw != null) await _replayJournal(sp, raw, mustReplay: mustReplay);
    return sp;
  }

  static Future<void> _replayJournal(
    SharedPreferences sp,
    String raw, {
    required bool mustReplay,
  }) async {
    Map<String, Object?> entries;
    try {
      final d = jsonDecode(raw);
      entries = d is Map ? Map<String, Object?>.from(d) : const {};
    } on FormatException {
      entries = const {};
    }
    final failed = <String, Object?>{};
    for (final e in entries.entries) {
      if (!await _restore(sp, e.key, _decodeBefore(e.value))) {
        failed[e.key] = e.value;
      }
    }
    if (failed.isEmpty) {
      // Nothing left to put back (or nothing readable): the journal is done.
      if (await _removeKey(sp, journalKey)) return;
      failed.addAll(entries);
    } else {
      try {
        await sp.setString(journalKey, jsonEncode(failed));
      } catch (_) {
        // The full journal is still stored; replaying it again is harmless.
      }
    }
    debugPrint(
      'SettingsRepository: recovery journal not fully replayed '
      '(${failed.keys.join(', ')})',
    );
    if (mustReplay) {
      throw StateError(
        'Unable to restore settings from the recovery journal '
        '(${failed.keys.join(', ')})',
      );
    }
  }

  static Future<bool> _removeKey(SharedPreferences sp, String key) async {
    try {
      return await sp.remove(key);
    } catch (_) {
      return false;
    }
  }

  // A stored value as a journal entry: [type, value], or [n] for "was absent".
  static List<Object>? _encodeBefore(Object? v) => switch (v) {
    null => const ['n'],
    final String v => ['s', v],
    final bool v => ['b', v],
    final int v => ['i', v],
    _ => null,
  };

  static Object? _decodeBefore(Object? entry) {
    if (entry is! List || entry.isEmpty) return null;
    return switch (entry[0]) {
      's' || 'b' || 'i' => entry.length > 1 ? entry[1] : null,
      _ => null,
    };
  }

  /// Puts [key] back to [value] (null: removed). False if the store refused or
  /// threw.
  static Future<bool> _restore(
    SharedPreferences sp,
    String key,
    Object? value,
  ) async {
    try {
      return switch (value) {
        null => await sp.remove(key),
        final String v => await sp.setString(key, v),
        final bool v => await sp.setBool(key, v),
        final int v => await sp.setInt(key, v),
        _ => true,
      };
    } catch (_) {
      return false;
    }
  }

  /// Writes every entry, or puts every key back as it was if one is refused.
  /// If putting a key back fails too, the values it should hold go into the
  /// recovery journal and the error says so.
  static Future<void> _write(
    SharedPreferences sp,
    Map<String, Object> writes,
  ) async {
    final before = {for (final k in writes.keys) k: sp.get(k)};
    final touched = <String>[];
    try {
      for (final e in writes.entries) {
        touched.add(e.key);
        final ok = switch (e.value) {
          final String v => await sp.setString(e.key, v),
          final bool v => await sp.setBool(e.key, v),
          final int v => await sp.setInt(e.key, v),
          _ => throw ArgumentError.value(e.value, e.key, 'unsupported type'),
        };
        if (!ok) throw StateError('Unable to save settings (${e.key})');
      }
    } catch (error) {
      final stuck = <String>[];
      for (final k in touched.reversed) {
        if (!await _restore(sp, k, before[k])) stuck.add(k);
      }
      if (stuck.isEmpty) rethrow;
      final journal = {for (final k in stuck) k: ?_encodeBefore(before[k])};
      var journaled = false;
      try {
        journaled = await sp.setString(journalKey, jsonEncode(journal));
      } catch (_) {
        // Reported below.
      }
      final msg =
          'Settings update failed ($error) and the rollback of '
          '${stuck.join(', ')} failed too; recovery journal '
          '${journaled ? 'saved, it is replayed on the next load' : 'could not be saved'}';
      debugPrint('SettingsRepository: $msg');
      throw StateError(msg);
    }
  }
}
