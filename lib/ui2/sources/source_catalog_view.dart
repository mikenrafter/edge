// The Source Catalog, drawn. Pure: it takes the `SourceCard.toJson()` maps
// (lib/sources/source_catalog.dart) and holds no AppState.
//
// Every absent value is "—". Nothing here turns a missing field into a word
// like "unknown", and nothing shows a full device id: the card is told apart
// from a same-model twin by its suffix alone.

import 'package:flutter/material.dart';

import '../../ble/adapters/signals.dart' show InputSignal;
import '../onboarding/profile_setup.dart' show formatDay;
import '../profile/devices.dart' show signalDisplayName;
import '../theme.dart';
import '../grammar.dart';

const kAbsent = '—';

/// What each collection behavior means, in one plain sentence.
const _collection = {
  'continuous': ('Continuous', 'records around the clock.'),
  'sampled': ('Sampled', 'read at intervals.'),
  'user-started': ('User-started', 'runs when you start a workout.'),
  'imported': ('Imported', 'brought in from a file.'),
  'derived': ('Derived', 'calculated from other sources.'),
};

const _types = {'band': 'Band', 'sensor': 'Sensor', 'phone': 'Phone'};

const _permissions = {'bluetooth': 'Bluetooth', 'motion': 'Motion and fitness'};

/// A signal's human name, or its raw name when this build has no such signal.
String signalNameOf(BuildContext c, Object? name) {
  for (final s in InputSignal.values) {
    if (s.name == name) return signalDisplayName(c, s);
  }
  return '$name';
}

/// "Tue 1 Sep 02:00" in the device's local time.
String stamp(BuildContext c, int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return '${formatDay(d)} ${_hm(d)}';
}

/// "Tue 1 Sep 02:00 to 03:00", with the end's day only when it differs.
String stampRange(int startSec, int endSec) {
  final a = DateTime.fromMillisecondsSinceEpoch(startSec * 1000);
  final b = DateTime.fromMillisecondsSinceEpoch(endSec * 1000);
  final end = a.year == b.year && a.month == b.month && a.day == b.day
      ? _hm(b)
      : '${formatDay(b)} ${_hm(b)}';
  return '${formatDay(a)} ${_hm(a)} to $end';
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class SourceCatalogView extends StatelessWidget {
  final List<Map<String, Object?>> cards;
  const SourceCatalogView({super.key, required this.cards});

  @override
  Widget build(BuildContext c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final card in cards) ...[
          _SourceCard(card),
          const SizedBox(height: S.x3),
        ],
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  final Map<String, Object?> card;
  const _SourceCard(this.card);

  List<String> _list(String key) => [
        for (final v in (card[key] as List? ?? const [])) '$v',
      ];

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final type = _types['${card['type']}'] ?? kAbsent;
    final model = card['model'] as String?;
    final signals = [
      for (final s in _list('signals')) signalNameOf(c, s),
      ..._list('supplies'),
    ];
    final collection = _collection[card['collection']];
    final coverage = (card['coverage'] as Map?)?.entries.toList();
    final lastSeen = (card['lastSeen'] as num?)?.toInt();
    final platform = card['platformIdSuffix'] as String?;
    final permissions = [
      for (final t in _list('permissions')) _permissions[t] ?? t,
    ];
    final limitations = _list('limitations');
    final uses = [
      for (final u in (card['uses'] as List? ?? const []))
        '${signalNameOf(c, (u as Map)['signal'])}: ${u['reason']}',
    ];
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${card['displayLabel']}',
              style: F.head.copyWith(color: p.ink)),
          Text('$type · ${model ?? kAbsent}',
              style: F.cap.copyWith(color: p.ink3)),
          _Fact('Collects',
              collection == null ? kAbsent : '${collection.$1}: ${collection.$2}'),
          _Fact('Signals', signals.isEmpty ? kAbsent : signals.join(', ')),
          _Fact('Used for', uses.isEmpty ? kAbsent : uses.join('\n')),
          _Fact(
            'Recorded',
            coverage == null || coverage.isEmpty
                ? kAbsent
                : [
                    for (final e in coverage)
                      '${signalNameOf(c, e.key)}: '
                          '${stamp(c, ((e.value as Map)['start'] as num).toInt())} to '
                          '${stamp(c, ((e.value as Map)['end'] as num).toInt())}',
                  ].join('\n'),
          ),
          _Fact('Last seen', lastSeen == null ? kAbsent : stamp(c, lastSeen)),
          _Fact('Permissions',
              permissions.isEmpty ? kAbsent : permissions.join(', ')),
          _Fact('ID', platform == null ? kAbsent : 'Ends in $platform'),
          _Fact('Limits',
              limitations.isEmpty ? kAbsent : limitations.join('\n')),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label, value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: 2),
          Text(value, style: F.cap.copyWith(color: p.ink2)),
        ],
      ),
    );
  }
}
