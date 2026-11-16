// Owner: HomeSnapshotStore owns the bounded durable Home presentation map.
// These health snapshots must disappear with their source store. They never
// supply analytics or fresh ring values. home_ring_cache.dart owns the codec.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../settings/settings_repository.dart';
import '../state/prefs.dart';
import '../sync/reset_gate.dart';

class HomeSnapshotStore {
  HomeSnapshotStore({this.limit = 32});
  static final local = HomeSnapshotStore();
  static const prefKey = 'ui.home_ring_details.v1';
  static final changes = ValueNotifier<int>(0);
  static int get generation => changes.value;
  static int _invalidating = 0;
  final int limit;
  final _entries = <String, dynamic>{};
  int _generation = generation;
  bool _restored = false;
  int? _saveScheduled;

  // CLAIM(home-cache-reset): invalidation clears the live map synchronously,
  // fences queued edits inside the settings queue, and deletes durable copies
  // after any already-started save [backup_folder_test; home_cache_lifecycle_test].
  static Future<void> invalidate() {
    _invalidating++;
    changes.value++;
    local._syncGeneration();
    return SettingsRepository.instance
        .update((d) => d.remove(prefKey), sections: const {})
        .then<void>((_) {})
        .catchError((Object error) {
          debugPrint('Home snapshot deletion failed: $error');
        })
        .whenComplete(() => _invalidating--);
  }

  void _syncGeneration() {
    if (_generation == generation) return;
    _generation = generation;
    _entries.clear();
    // The old disk copy may still be waiting for its deletion queue slot.
    _restored = true;
    _saveScheduled = null;
  }

  void _restore() {
    _syncGeneration();
    if (_restored || !Prefs.loaded) return;
    _restored = true;
    if (_invalidating > 0) return;
    try {
      final decoded = jsonDecode(Prefs.getString(prefKey, '{}'));
      if (decoded is Map) {
        _entries.addAll(
          Map<String, dynamic>.fromEntries(
            decoded.entries
                .where((e) => e.key is String && e.value is Map)
                .take(limit)
                .map((e) => MapEntry(e.key as String, e.value)),
          ),
        );
      }
    } catch (_) {
      /* A damaged secondary cache loses only its presentation. */
    }
  }

  Map<String, dynamic>? read(String key) {
    _restore();
    final raw = _entries[key];
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  void record(String key, Map<String, Object?> value) {
    _restore();
    if (ResetGate.active) return;
    if (jsonEncode(_entries[key]) == jsonEncode(value)) return;
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
    final token = generation;
    if (_saveScheduled == token) return;
    _saveScheduled = token;
    scheduleMicrotask(() async {
      if (token != generation) return;
      _saveScheduled = null;
      try {
        await SettingsRepository.instance.update((d) {
          // Check in the serialized edit, not before awaiting the queue.
          if (token == generation && !ResetGate.active) {
            d.setString(prefKey, jsonEncode(_entries));
          }
        }, sections: const {});
      } catch (_) {
        /* Stored reads remain authoritative if saving fails. */
      }
    });
  }
}
