// Resolved data, drawn: per signal a timeline of who owned each stretch, then
// one row per stretch with the winner, the alternatives, whether they agreed
// and the reason. Pure: it takes `ResolvedInterval.toJson()` maps and a
// `{deviceId: label}` map.
//
// A gap is drawn as a gap and its winner is "—". Agreement is shown beside the
// winner and never decides it.

import 'package:flutter/material.dart';

import '../../sources/resolved_window.dart'
    show kResolvedWindowChoices;
import '../grammar.dart';
import '../theme.dart';
import 'source_catalog_view.dart' show kAbsent, signalNameOf, stampRange;

const _agreement = {
  'agree': 'Sources agree',
  'disagree': 'Sources disagree',
  'single': 'Single source',
  'none': 'No comparison',
};

const _kinds = {
  'single': 'Single source',
  'overlap': 'Overlap',
  'gap': 'Gap',
};

class ResolvedDataView extends StatelessWidget {
  final List<Map<String, Object?>> rows;
  final Map<String, String> names;
  const ResolvedDataView({super.key, required this.rows, required this.names});

  @override
  Widget build(BuildContext c) {
    final bySignal = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      (bySignal['${r['signal']}'] ??= []).add(r);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in bySignal.entries)
          Section(
            signalNameOf(c, e.key),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Timeline(signal: e.key, rows: e.value),
                const SizedBox(height: S.x3),
                for (final r in e.value) ...[
                  _Row(r, names),
                  const SizedBox(height: S.x2),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

Color _fillOf(P p, String kind) => switch (kind) {
      'single' => p.on(C.blue),
      'overlap' => p.on(C.green),
      _ => p.line,
    };

class _Timeline extends StatelessWidget {
  final String signal;
  final List<Map<String, Object?>> rows;
  const _Timeline({required this.signal, required this.rows});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      label: 'Timeline of who owned each stretch',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: ValueKey('resolved-timeline:$signal'),
            height: S.x4,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in rows)
                  Expanded(
                    // Width follows duration. A unique key per segment, the
                    // inner one names the kind for tests and tools.
                    key: ValueKey('seg:$signal:${r['start']}'),
                    flex: (((r['end'] as num) - (r['start'] as num)).toInt())
                        .clamp(1, 1 << 30),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 1),
                      child: DecoratedBox(
                        key: ValueKey('segment:${r['kind']}'),
                        decoration: BoxDecoration(
                          color: _fillOf(p, '${r['kind']}'),
                          border: r['kind'] == 'gap'
                              ? Border.all(color: p.ink3)
                              : null,
                          borderRadius: R.rSm,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: S.x2),
          Wrap(
            spacing: S.x3,
            runSpacing: S.x1,
            children: [
              for (final k in _kinds.entries)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _fillOf(p, k.key),
                        border:
                            k.key == 'gap' ? Border.all(color: p.ink3) : null,
                        borderRadius: R.rSm,
                      ),
                    ),
                    const SizedBox(width: S.x1),
                    Text(k.value, style: F.over.copyWith(color: p.ink3)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Map<String, Object?> row;
  final Map<String, String> names;
  const _Row(this.row, this.names);

  String _name(Object? id) => id == null ? kAbsent : names['$id'] ?? kAbsent;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final start = (row['start'] as num).toInt(), end = (row['end'] as num).toInt();
    final alternatives = [
      for (final id in (row['alternatives'] as List? ?? const [])) _name(id),
    ];
    final values = (row['values'] as Map? ?? const {});
    return Container(
      key: ValueKey('resolved-row:${row['signal']}:${row['start']}'),
      width: double.infinity,
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stampRange(start, end),
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x1),
          Text('WINNER', style: F.over.copyWith(color: p.ink3)),
          Text(_name(row['winner']),
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          if (alternatives.isNotEmpty) ...[
            const SizedBox(height: S.x1),
            Text('ALSO RECORDED', style: F.over.copyWith(color: p.ink3)),
            Text(alternatives.join(', '), style: F.cap.copyWith(color: p.ink2)),
          ],
          const SizedBox(height: S.x1),
          Text(_agreement['${row['agreement']}'] ?? kAbsent,
              style: F.cap.copyWith(color: p.ink2)),
          if (values.isNotEmpty)
            Text(
              'Mean heart rate: ${[
                for (final e in values.entries)
                  '${_name(e.key)} ${(e.value as num).round()} bpm',
              ].join(', ')}',
              style: F.cap.copyWith(color: p.ink2),
            ),
          const SizedBox(height: S.x1),
          Text('${row['reason']}', style: F.cap.copyWith(color: p.ink3)),
        ],
      ),
    );
  }
}


/// The window choice: presets and "No cutoff". Pure; the screen stores it.
class ResolvedWindowPicker extends StatelessWidget {
  final int? days;
  final ValueChanged<int?> onChanged;
  const ResolvedWindowPicker({super.key, required this.days, required this.onChanged});

  static String _label(int? d) => switch (d) {
        null => 'No cutoff',
        1 => '1 day',
        final n => '$n days',
      };

  @override
  Widget build(BuildContext c) {
    final i = kResolvedWindowChoices.indexOf(days);
    return SubTabs(
      [for (final d in kResolvedWindowChoices) _label(d)],
      i < 0 ? 0 : i,
      (j) => onChanged(kResolvedWindowChoices[j]),
      color: C.teal,
    );
  }
}
