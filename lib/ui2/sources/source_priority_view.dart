// The per-signal priority editor, drawn. Pure: it takes
// `{signal, order, labels: {deviceId: label}}` maps and two callbacks.
//
// One section per signal, with or without a second source. Moving a source
// only edits a pending order; the consequence is written out BEFORE anything
// saves. Saving applies to current and future computation. Rebuilding history
// is a separate Advanced action with its cost stated and a confirmation.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../grammar.dart';
import '../theme.dart';
import 'source_catalog_view.dart' show signalNameOf;

/// Days of raw readings kept on the phone. Mirrors `rawRetentionDays`
/// (compute/derivation_engine.dart); a test holds the two equal.
const int kRebuildRawDays = 3;

class SourcePriorityEditor extends StatefulWidget {
  final List<Map<String, Object?>> signals;
  final void Function(String signal, List<String> order) onSave;
  final VoidCallback onRebuild;

  /// Back to the default order for one signal. Offered only for a signal whose
  /// map says `userSet: true`.
  final void Function(String signal)? onReset;
  const SourcePriorityEditor({
    super.key,
    required this.signals,
    required this.onSave,
    required this.onRebuild,
    this.onReset,
  });

  @override
  State<SourcePriorityEditor> createState() => _SourcePriorityEditorState();
}

class _SourcePriorityEditorState extends State<SourcePriorityEditor> {
  /// Unsaved orders, by signal. Dropped once the saved order catches up.
  final Map<String, List<String>> _pending = {};
  bool _confirming = false;

  List<String> _saved(Map<String, Object?> s) => [
        for (final id in (s['order'] as List)) '$id',
      ];

  @override
  void didUpdateWidget(SourcePriorityEditor old) {
    super.didUpdateWidget(old);
    for (final s in widget.signals) {
      final name = '${s['signal']}';
      if (_pending[name]?.join('|') == _saved(s).join('|')) _pending.remove(name);
    }
  }

  void _move(Map<String, Object?> s, String id, int by) {
    final name = '${s['signal']}';
    final order = [..._pending[name] ?? _saved(s)];
    final i = order.indexOf(id), j = i + by;
    if (i < 0 || j < 0 || j >= order.length) return;
    order.insert(j, order.removeAt(i));
    setState(() => _pending[name] = order);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in widget.signals) _section(c, p, s),
        Section(
          'Advanced',
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saving an order changes current and future days only. Days '
                  'already calculated keep the numbers they have.',
                  style: F.cap.copyWith(color: p.ink2),
                ),
                if (_pending.isNotEmpty) ...[
                  const SizedBox(height: S.x2),
                  Text('You have unsaved changes. Rebuilding uses the saved order.',
                      style: F.cap.copyWith(color: p.on(C.orange))),
                ],
                const SizedBox(height: S.x3),
                if (!_confirming)
                  BigButton('Rebuild history with this priority',
                      soft: true,
                      color: C.orange,
                      onTap: () => setState(() => _confirming = true))
                else
                  Column(
                    key: const ValueKey('rebuild-cost'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'This recalculates every day that still has readings on '
                        'this phone, which is the last $kRebuildRawDays days, '
                        'using the saved order. It can take several minutes and '
                        'uses battery. Older days keep their stored numbers.',
                        style: F.cap.copyWith(color: p.ink),
                      ),
                      const SizedBox(height: S.x3),
                      BigButton('Rebuild now',
                          key: const ValueKey('rebuild-confirm'),
                          color: C.orange,
                          onTap: () {
                            setState(() => _confirming = false);
                            widget.onRebuild();
                          }),
                      const SizedBox(height: S.x2),
                      BigButton('Cancel',
                          soft: true,
                          color: C.blue,
                          onTap: () => setState(() => _confirming = false)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext c, P p, Map<String, Object?> s) {
    final name = '${s['signal']}';
    final saved = _saved(s);
    final order = _pending[name] ?? saved;
    final labels = (s['labels'] as Map? ?? const {});
    String label(String id) => '${labels[id] ?? '—'}';
    final changed = order.join('|') != saved.join('|');
    final signalLabel = signalNameOf(c, name);
    return Section(
      signalLabel,
      Surface(
        key: ValueKey('priority:$name'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < order.length; i++)
              Row(
                children: [
                  Text('${i + 1}', style: F.cap.copyWith(color: p.ink3)),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Text(label(order[i]),
                        style: F.body.copyWith(color: p.ink)),
                  ),
                  if (order.length > 1) ...[
                    _Move(
                      key: ValueKey('priority-up:$name:${order[i]}'),
                      icon: LucideIcons.arrowUp,
                      semantic: 'Move ${label(order[i])} up for $signalLabel',
                      onTap: i == 0 ? null : () => _move(s, order[i], -1),
                    ),
                    _Move(
                      key: ValueKey('priority-down:$name:${order[i]}'),
                      icon: LucideIcons.arrowDown,
                      semantic: 'Move ${label(order[i])} down for $signalLabel',
                      onTap: i == order.length - 1
                          ? null
                          : () => _move(s, order[i], 1),
                    ),
                  ],
                ],
              ),
            if (order.length < 2)
              Text('Only one source provides this, so there is nothing to order.',
                  style: F.cap.copyWith(color: p.ink3)),
            if (changed) ...[
              const SizedBox(height: S.x3),
              Column(
                key: ValueKey('priority-consequence:$name'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${label(order.first)} will win $signalLabel whenever it is '
                    'recording. This applies to current and future days. '
                    'History stays as calculated until you rebuild it.',
                    style: F.cap.copyWith(color: p.ink),
                  ),
                ],
              ),
            ],
            if (s['userSet'] == true && widget.onReset != null)
              Pressable(
                onTap: () => widget.onReset!(name),
                semanticLabel: 'Reset $signalLabel to the default order',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: S.x2),
                  child: Text('Back to the default order',
                      style: F.cap.copyWith(color: p.on(C.blue))),
                ),
              ),
            if (order.length > 1) ...[
              const SizedBox(height: S.x3),
              BigButton('Save order',
                  key: ValueKey('priority-save:$name'),
                  color: C.blue,
                  soft: !changed,
                  onTap: changed ? () => widget.onSave(name, order) : null),
            ],
          ],
        ),
      ),
    );
  }
}

class _Move extends StatelessWidget {
  final IconData icon;
  final String semantic;
  final VoidCallback? onTap;
  const _Move({super.key, required this.icon, required this.semantic, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: semantic,
      child: Icon(icon, size: 20, color: onTap == null ? p.ink3 : p.on(C.blue)),
    );
  }
}
