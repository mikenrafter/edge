// The Source Catalog: what every source is, what it supplies, and where it is
// currently the one in use. Plus the per-signal priority model behind the
// editor, and the one service the Sources screens read.
//
// A READ SEAM, like resolved_data.dart: `device`, `device_coverage` and
// `signal_priority` through `LocalDb`, no analytics, nothing from compute/.
// "Who is using this source" is `signalWinners`, the function the metric
// screens already caption themselves with, so the catalog and those captions
// cannot disagree.

import '../ble/adapters/_registry.dart' show declaredSignals, kBandRegistry;
import '../ble/adapters/signals.dart' show InputSignal;
import '../data/db.dart' show LocalDb;
import '../ui2/profile/devices.dart'
    show
        HealthSource,
        bandLabelFor,
        contendedSignalsOf,
        declaringDeviceIds,
        deviceIdOf,
        signalWinners;
import 'resolved_data.dart';

/// Adapters whose link is armed by a workout and only by one.
const _workoutArmed = {'ble_hrs', 'polar_pmd'};

const _bluetooth = 'bluetooth';

class SourceCard {
  final String? deviceId, model, platformIdSuffix, identitySuffix;
  final String name, type, collection;
  final List<String> signals, supplies, permissions, limitations;
  final Map<String, ({int start, int end})>? coverage;
  final int? lastSeen;
  final List<SourceUse> uses;

  const SourceCard({
    required this.deviceId,
    required this.name,
    required this.type,
    required this.model,
    required this.platformIdSuffix,
    required this.identitySuffix,
    required this.signals,
    required this.supplies,
    required this.collection,
    required this.coverage,
    required this.lastSeen,
    required this.permissions,
    required this.limitations,
    required this.uses,
  });

  /// `name`, or `name · suffix` when two devices could otherwise look alike.
  String get displayLabel =>
      identitySuffix == null ? name : '$name · $identitySuffix';

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'displayLabel': displayLabel,
        'type': type,
        'model': model,
        'platformIdSuffix': platformIdSuffix,
        'identitySuffix': identitySuffix,
        'signals': signals,
        'supplies': supplies,
        'collection': collection,
        'coverage': coverage == null
            ? null
            : {
                for (final e in coverage!.entries)
                  e.key: {'start': e.value.start, 'end': e.value.end},
              },
        'lastSeen': lastSeen,
        'permissions': permissions,
        'limitations': limitations,
        'uses': [for (final u in uses) u.toJson()],
      };
}

/// A signal this source is currently the winner of, and why.
class SourceUse {
  final String signal, reasonCode, reason;
  const SourceUse(this.signal, this.reasonCode, this.reason);

  Map<String, Object?> toJson() =>
      {'signal': signal, 'reasonCode': reasonCode, 'reason': reason};
}

class SourceService {
  final List<HealthSource> sources;
  final DateTime Function() now;

  SourceService({required this.sources, DateTime Function()? now})
      : now = now ?? DateTime.now;

  Future<List<SourceCard>> cards() async {
    final rows = {
      for (final r in await LocalDb.deviceRows()) r['id'] as String: r,
    };
    final extents = await LocalDb.coverageExtentByDevice();
    final stored = await LocalDb.signalPriorities();
    final declared = {for (final s in sources) ...declaredSignals(s.family)};
    final winners = await signalWinners(
      sources,
      requires: declared,
      stored: stored,
      now: now(),
    );
    final suffixes = _identitySuffixes([
      for (final id in sources.map(deviceIdOf).nonNulls)
        if (id.isNotEmpty) id,
    ]);

    return [
      for (final s in sources)
        _card(
          s,
          row: rows[deviceIdOf(s)],
          extent: extents[deviceIdOf(s)],
          suffix: suffixes[deviceIdOf(s)],
          uses: [
            for (final sig in InputSignal.values)
              if (declared.contains(sig) &&
                  winners[sig] != null &&
                  winners[sig] == deviceIdOf(s))
                _use(sig, sources, stored),
          ],
        ),
    ];
  }

  /// Resolves [signal] over `[from, to)` (epoch seconds, `to` exclusive).
  Future<List<ResolvedInterval>> resolve({
    required InputSignal signal,
    required int from,
    required int to,
  }) =>
      resolveIntervals(signal: signal, from: from, to: to, now: now());

  /// One `{signal, order, contended}` per signal at least one source declares,
  /// contended or not. `order` lists only the devices that declare the signal.
  Future<List<Map<String, Object?>>> prioritySignals() async {
    final stored = await LocalDb.signalPriorities();
    final contended = contendedSignalsOf(sources).toSet();
    return [
      for (final sig in InputSignal.values)
        if (declaringDeviceIds(sources, sig) case final declaring
            when declaring.isNotEmpty)
          {
            'signal': sig.name,
            'order': _order(declaring, stored[sig.name] ?? const []),
            'contended': contended.contains(sig),
          },
    ];
  }

  /// Writes [order] for [signal] only. Current and future computation follow
  /// it; stored days and series are not touched and nothing re-derives.
  Future<void> savePriority(InputSignal signal, List<String> order) =>
      LocalDb.setSignalPriority(signal, order);

  /// The order the editor shows: a stored order (devices that no longer
  /// declare the signal dropped, new ones appended), or with nothing stored the
  /// order the engine really uses, the primary first.
  static List<String> _order(List<String> declaring, List<String> stored) {
    if (stored.isNotEmpty) {
      return [
        for (final id in stored)
          if (declaring.contains(id)) id,
        for (final id in declaring)
          if (!stored.contains(id)) id,
      ];
    }
    return [
      if (declaring.contains(LocalDb.kPrimaryDeviceId)) LocalDb.kPrimaryDeviceId,
      for (final id in declaring)
        if (id != LocalDb.kPrimaryDeviceId) id,
    ];
  }
}

SourceUse _use(
  InputSignal sig,
  List<HealthSource> sources,
  Map<String, List<String>> stored,
) {
  if (declaringDeviceIds(sources, sig).length == 1) {
    return SourceUse(sig.name, 'onlySource', 'The only source of this signal.');
  }
  return (stored[sig.name] ?? const []).isNotEmpty
      ? SourceUse(sig.name, 'userPriority', 'First in your order for this signal.')
      : SourceUse(sig.name, 'defaultPrimary',
          'No order is set, so the band is used.');
}

SourceCard _card(
  HealthSource s, {
  required Map<String, Object?>? row,
  required Map<String, ({int start, int end})>? extent,
  required String? suffix,
  required List<SourceUse> uses,
}) {
  final isPhone = !s.isBand && s.deviceId == null;
  final framed = kBandRegistry.any((e) => e.id == s.family && e.isFramed);
  final signals = [for (final sig in declaredSignals(s.family)) sig.name]..sort();
  final remote = (row?['remote_id'] as String?)?.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final seen = [
    (row?['last_seen'] as num?)?.toInt(),
    s.lastData == null ? null : s.lastData!.millisecondsSinceEpoch ~/ 1000,
  ].nonNulls;
  final collection = s.isBand || framed
      ? 'continuous'
      : isPhone || !_workoutArmed.contains(s.family)
          ? 'sampled'
          : 'user-started';
  return SourceCard(
    deviceId: deviceIdOf(s),
    name: s.name,
    type: s.isBand ? 'band' : (isPhone ? 'phone' : 'sensor'),
    model: bandLabelFor(s.family),
    platformIdSuffix: remote == null || remote.isEmpty
        ? null
        : remote.substring(remote.length > 4 ? remote.length - 4 : 0),
    identitySuffix: suffix,
    signals: signals,
    supplies: [if (isPhone) 'steps'],
    collection: collection,
    coverage: extent == null || extent.isEmpty ? null : extent,
    lastSeen: seen.isEmpty ? null : seen.reduce((a, b) => a > b ? a : b),
    permissions: [if (!isPhone) _bluetooth else 'motion'],
    limitations: [
      if (s.experimental)
        'Experimental. No one on this project has held this model, so its '
            'readings have not been checked against the device.',
      if (collection == 'user-started') 'Records only while a workout is running.',
      if (isPhone) 'Reports steps only.',
      if (!isPhone && signals.isEmpty)
        'Declares no signals yet, so what it sends is stored but used for no metric.',
    ],
    uses: uses,
  );
}

/// The shortest tail of each id, 4 to 6 characters and never the whole id,
/// that no other id in [ids] shares. Depends on the set, not its order.
Map<String, String> _identitySuffixes(List<String> ids) {
  String tail(String id, int n) => id.substring(id.length - n);
  int cap(String id) => id.length - 1 < 6 ? id.length - 1 : 6;
  return {
    for (final id in ids)
      if (id.length > 1)
        id: () {
        final max = cap(id);
        for (var n = max < 4 ? max : 4; n < max; n++) {
          if (ids.every((o) => o == id || o.length < n || tail(o, n) != tail(id, n))) {
            return tail(id, n);
          }
        }
        return tail(id, max);
      }(),
  };
}
