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

/// Keeps a bounded local history of screen loads. OFF until the Developer
/// switch turns it on: nobody opted in, so by default nothing is recorded and
/// nothing is written. Samples taken inside a screen route live in their own
/// ring; background traffic (derive, sync) has a small ring of its own and can
/// never push out a screen's breakdown. Saved at most once per
/// [saveInterval], and on [flush].
class LoadTimings {
  LoadTimings({
    bool? enabled,
    this.saveInterval = const Duration(seconds: 5),
    Future<void> Function(String encoded)? persist,
  })  : _enabledOverride = enabled,
        _persist = persist;

  static const prefKey = 'developer.load_timings.v1';
  static const enabledKey = 'developer.load_timings_enabled.v1';
  static const limit = 128;
  static const backgroundLimit = 32;
  static final shared = LoadTimings();
  static final _scope = Object();
  static const _background = 'background';
  final Duration saveInterval;
  final bool? _enabledOverride;
  final Future<void> Function(String encoded)? _persist;
  final _samples = <LoadTiming>[]; // screen loads, oldest first
  final _backgroundSamples = <LoadTiming>[];
  bool _restored = false, _changed = false;
  Timer? _timer;
  Future<void>? _saving;

  static String get currentRoute =>
      Zone.current[_scope] as String? ?? _background;

  bool get enabled => _enabledOverride ?? Prefs.getBool(enabledKey, false);
  void setEnabled(bool on) => Prefs.setBool(enabledKey, on);

  /// Writes what is pending now (the debounce is for the hot path only).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _saving;
    if (_changed) await (_saving = _save());
  }

  List<LoadTiming> get samples {
    _restore();
    return List.unmodifiable([..._backgroundSamples, ..._samples]);
  }

  void _restore() {
    if (_restored) return;
    _restored = true;
    try {
      final rows = jsonDecode(Prefs.getString(prefKey, '[]')) as List;
      for (final r in rows.take(limit + backgroundLimit)) {
        if (r is Map &&
            r['name'] is String &&
            r['phase'] is String &&
            r['us'] is int &&
            r['route'] is String) {
          final t = LoadTiming(r['name'], r['phase'], r['us'], r['route']);
          (t.route == _background ? _backgroundSamples : _samples).add(t);
        }
      }
    } catch (_) {
      /* A damaged diagnostic cache is disposable. */
    }
  }

  Future<T> scope<T>(String route, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_scope: route});

  void record(String name, String phase, int micros, {String? route}) {
    if (!enabled) return;
    _restore();
    final timing = LoadTiming(name, phase, micros, route ?? currentRoute);
    bool milestone(LoadTiming s) =>
        s.phase == 'first usable rows' || s.phase == 'all details ready';
    if (timing.route == _background) {
      _backgroundSamples.add(timing);
      if (_backgroundSamples.length > backgroundLimit) _backgroundSamples.removeAt(0);
    } else {
      _samples.add(timing);
      if (_samples.where(milestone).length > 24) {
        _samples.removeAt(_samples.indexWhere(milestone));
      }
      if (_samples.length > limit) {
        _samples.removeAt(_samples.indexWhere((s) => !milestone(s)));
      }
    }
    _changed = true;
    _timer ??= Timer(saveInterval, () {
      _timer = null;
      _saving = _save();
    });
  }

  Future<void> _save() async {
    try {
      while (_changed) {
        _changed = false;
        final encoded = jsonEncode([
          for (final r in [..._backgroundSamples, ..._samples]) r.toJson(),
        ]);
        final persist = _persist;
        if (persist != null) {
          await persist(encoded);
        } else {
          await SettingsRepository.instance.update(
            (d) => d.setString(prefKey, encoded),
            sections: const {},
          );
        }
      }
    } catch (_) {
      /* Diagnostics never fail a read or commit. */
    }
  }

  Future<T> measure<T>(
    String name,
    String phase,
    Future<T> Function() body,
  ) async {
    if (!enabled) return body();
    final clock = Stopwatch()..start();
    try {
      return await body();
    } finally {
      record(name, phase, clock.elapsedMicroseconds);
    }
  }
}
