// Owner: LoadTimings owns a bounded local diagnostic history. No SQL arguments
// or health values are retained. Overlapping read durations are never summed.
import 'dart:async';
import 'dart:convert';

import '../settings/settings_repository.dart';
import '../state/prefs.dart';

class LoadTiming {
  const LoadTiming(this.name, this.phase, this.micros, this.route);
  final String name, phase, route;
  final int micros;
  Map<String, Object> toJson() => {
    'name': name,
    'phase': phase,
    'us': micros,
    'route': route,
  };
}

class LoadTimings {
  static const prefKey = 'developer.load_timings.v1';
  static const limit = 128;
  static final shared = LoadTimings();
  static final _scope = Object();
  final _samples = <LoadTiming>[];
  bool _restored = false, _changed = false;
  Future<void>? _save;
  static String get currentRoute =>
      Zone.current[_scope] as String? ?? 'background';
  Future<void> flush() async => _save;
  List<LoadTiming> get samples {
    _restore();
    return List.unmodifiable(_samples);
  }

  void _restore() {
    if (_restored) return;
    _restored = true;
    try {
      final rows = jsonDecode(Prefs.getString(prefKey, '[]')) as List;
      for (final r in rows.take(limit)) {
        if (r is Map &&
            r['name'] is String &&
            r['phase'] is String &&
            r['us'] is int &&
            r['route'] is String) {
          _samples.add(LoadTiming(r['name'], r['phase'], r['us'], r['route']));
        }
      }
    } catch (_) {
      /* A damaged diagnostic cache is disposable. */
    }
  }

  Future<T> scope<T>(String route, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_scope: route});
  void record(String name, String phase, int micros, {String? route}) {
    _restore();
    _samples.add(LoadTiming(name, phase, micros, route ?? currentRoute));
    bool milestone(LoadTiming s) =>
        s.phase == 'first usable rows' || s.phase == 'all details ready';
    if (_samples.where(milestone).length > 24) {
      _samples.removeAt(_samples.indexWhere(milestone));
    }
    if (_samples.length > limit) {
      _samples.removeAt(_samples.indexWhere((s) => !milestone(s)));
    }
    _changed = true;
    _save ??= Future.microtask(() async {
      try {
        while (_changed) {
          _changed = false;
          final encoded = jsonEncode([for (final r in _samples) r.toJson()]);
          await SettingsRepository.instance.update(
            (d) => d.setString(prefKey, encoded),
            sections: const {},
          );
        }
      } catch (_) {
        /* Diagnostics never fail a read or commit. */
      } finally {
        _save = null;
      }
    });
  }

  Future<T> measure<T>(
    String name,
    String phase,
    Future<T> Function() body,
  ) async {
    final clock = Stopwatch()..start();
    try {
      return await body();
    } finally {
      record(name, phase, clock.elapsedMicroseconds);
    }
  }
}
