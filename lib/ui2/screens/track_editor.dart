// TrackEditor owns its unsaved form and history. Saving replaces both atomically.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import '../../data/day_label.dart';
import '../../data/tracks_store.dart';
import '../ui2.dart';
import 'track_editor_fields.dart';
import 'tracks_text.dart';

class TrackEditor extends StatefulWidget {
  const TrackEditor({super.key, required this.store, this.initial});
  final TracksStore store;
  final TrackDefinition? initial;
  @override
  State<TrackEditor> createState() => _TrackEditorState();
}

class _TrackEditorState extends State<TrackEditor> {
  late final TrackDefinition _initial =
      widget.initial ??
      TrackDefinition(
        id: 'custom:${DateTime.now().microsecondsSinceEpoch}',
        name: '',
        icon: '○',
        kind: 'activity',
      );
  late String _name = _initial.name,
      _icon = _initial.icon,
      _unit = _initial.unit,
      _kind = _initial.kind;
  late final _kinetics = TrackKineticsDraft(_initial.kinetics);
  late final _sub = [for (final s in _initial.subActivities) TrackSubDraft(s)];
  late final _roles = {..._initial.roles}, _systems = {..._initial.systems};
  late String _min = '${_initial.detectionMin}',
      _max = '${_initial.detectionMax}';
  late bool _noClean = _initial.noUnadjustedData,
      _enabled = _initial.enabled,
      _prescribed = _initial.prescribed;
  List<TrackRangeDraft>? _history;
  final _customSystem = TextEditingController();
  bool _failed = false, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _customSystem.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final history = widget.initial == null
          ? <TrackSetupRange>[]
          : await widget.store.history(_initial.id);
      if (mounted) {
        setState(() {
          _history = [for (final r in history) TrackRangeDraft(r)];
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _save() async {
    if (_saving || _history == null) return;
    TrackDefinition definition;
    try {
      final min = int.tryParse(_min), max = int.tryParse(_max);
      if (min == null || max == null) throw const FormatException('bounds');
      definition = TrackDefinition(
        id: _initial.id,
        name: _name.trim(),
        icon: _icon.trim(),
        kind: _kind,
        unit: _unit.trim(),
        kinetics: _kinetics.read(),
        subActivities: [for (final s in _sub) s.read()],
        roles: _roles.toList(),
        systems: _systems.toList(),
        detectionMin: min,
        detectionMax: max,
        noUnadjustedData: _noClean,
        prescribed: _prescribed,
        enabled: _enabled,
        loggingComplete: _initial.loggingComplete,
        loggingCompleteSinceMs: _initial.loggingCompleteSinceMs,
        sources: _initial.sources,
      );
      if (definition.validationError != null) {
        throw const FormatException('definition');
      }
    } on FormatException {
      setState(() => _error = 'Invalid');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.saveDefinition(
        definition,
        history: [for (final r in _history!) r.read(_initial.id, _unit.trim())],
      );
      if (mounted) Navigator.of(context).pop(definition);
    } on ArgumentError {
      if (mounted) setState(() => _error = 'Invalid');
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addRange({bool daily = false}) {
    final now = clock.now();
    final date = todayLabel(now);
    setState(
      () => _history!.add(
        TrackRangeDraft(
          daily
              ? DoneRange(
                  id: 'range:${now.microsecondsSinceEpoch}',
                  trackId: _initial.id,
                  startDate: date,
                )
              : DoneRange(
                  id: 'range:${now.microsecondsSinceEpoch}',
                  trackId: _initial.id,
                  startDate: date,
                  untilDate: date,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    return Scaffold(
      backgroundColor: P.of(context).bg,
      appBar: AppBar(
        title: Text(text(widget.initial == null ? 'Create' : 'Edit')),
        actions: [
          TextButton(
            key: const ValueKey('track-save'),
            onPressed: _saving || _history == null ? null : _save,
            child: Text(text('Save')),
          ),
        ],
      ),
      body: _history == null
          ? Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(text('Failed')),
                        TextButton(
                          onPressed: _loadHistory,
                          child: Text(text('Retry')),
                        ),
                      ],
                    )
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(S.x4),
              children: [
                if (_error != null)
                  Text(text(_error!), key: const ValueKey('track-form-error')),
                TextFormField(
                  key: const ValueKey('track-name'),
                  initialValue: _name,
                  decoration: InputDecoration(labelText: text('Name')),
                  onChanged: (value) => _name = value,
                ),
                const SizedBox(height: S.x3),
                TextFormField(
                  key: const ValueKey('track-icon'),
                  initialValue: _icon,
                  decoration: InputDecoration(labelText: text('Icon')),
                  onChanged: (value) => _icon = value,
                ),
                const SizedBox(height: S.x3),
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: InputDecoration(labelText: text('Kind')),
                  items: [
                    for (final pair in const {
                      'consumed': 'Consumed',
                      'activity': 'Activity',
                      'condition': 'Condition',
                    }.entries)
                      DropdownMenuItem(
                        value: pair.key,
                        child: Text(text(pair.value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) _kind = value;
                  },
                ),
                const SizedBox(height: S.x3),
                TextFormField(
                  key: const ValueKey('track-unit'),
                  initialValue: _unit,
                  decoration: InputDecoration(labelText: text('Unit')),
                  onChanged: (value) => _unit = value,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(text('Enabled')),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
                // ↳ CLAIM(never-ask-skip-prescribed): the flag that keeps a track
                // out of randomized experiments; a medication is always on.
                CheckboxListTile(
                  key: const ValueKey('track-prescribed'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(text('Prescribed')),
                  subtitle: Text(text('PrescribedNote'), style: F.cap),
                  value: _prescribed || _initial.id.startsWith('med:'),
                  onChanged: _initial.id.startsWith('med:')
                      ? null
                      : (value) => setState(() => _prescribed = value == true),
                ),
                _section(text('Kinetics'), [
                  Text(text('KineticsNote'), style: F.cap),
                  const SizedBox(height: S.x3),
                  TrackKineticsFields(draft: _kinetics),
                ], open: true),
                _section(text('Roles'), [
                  for (final role in {...trackRoles, ..._roles})
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(text(trackRoleLabels[role] ?? role)),
                      value: _roles.contains(role),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _roles.add(role);
                        } else {
                          _roles.remove(role);
                        }
                      }),
                    ),
                ]),
                _section(text('Systems'), [
                  for (final system in {...trackSystems, ..._systems})
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(text(trackSystemLabels[system] ?? system)),
                      value: _systems.contains(system),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _systems.add(system);
                        } else {
                          _systems.remove(system);
                        }
                      }),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('track-custom-system'),
                          controller: _customSystem,
                          decoration: InputDecoration(
                            labelText: text('CustomSystem'),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: text('CustomSystem'),
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          final value = _customSystem.text.trim();
                          if (value.isNotEmpty) {
                            setState(() {
                              _systems.add(value);
                              _customSystem.clear();
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ]),
                _section(text('Subactivities'), [
                  for (final sub in _sub)
                    ExpansionTile(
                      key: ValueKey('sub-${sub.id}'),
                      title: Text(
                        sub.name.isEmpty ? text('Subactivity') : sub.name,
                      ),
                      children: [
                        TextFormField(
                          key: ValueKey('sub-${sub.id}-name'),
                          initialValue: sub.name,
                          decoration: InputDecoration(labelText: text('Name')),
                          onChanged: (value) =>
                              setState(() => sub.name = value),
                        ),
                        Text(text('Overrides'), style: F.cap),
                        TrackKineticsFields(
                          draft: sub.kinetics,
                          prefix: 'sub-${sub.id}',
                        ),
                        TextButton(
                          onPressed: () => setState(() => _sub.remove(sub)),
                          child: Text(text('Remove')),
                        ),
                      ],
                    ),
                  TextButton(
                    key: const ValueKey('track-add-subactivity'),
                    onPressed: () => setState(
                      () => _sub.add(
                        TrackSubDraft(
                          TrackSubActivity(
                            id: 'sub:${DateTime.now().microsecondsSinceEpoch}',
                            name: '',
                          ),
                        ),
                      ),
                    ),
                    child: Text(text('AddSubactivity')),
                  ),
                ]),
                _section(text('Bounds'), [
                  Text(text('BoundsNote'), style: F.cap),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: const ValueKey('track-detection-min'),
                          initialValue: _min,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: text('Min')),
                          onChanged: (value) => _min = value,
                        ),
                      ),
                      const SizedBox(width: S.x3),
                      Expanded(
                        child: TextFormField(
                          key: const ValueKey('track-detection-max'),
                          initialValue: _max,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: text('Max')),
                          onChanged: (value) => _max = value,
                        ),
                      ),
                    ],
                  ),
                ]),
                _section(text('History'), [
                  SwitchListTile(
                    key: const ValueKey('track-no-clean'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(text('NoClean')),
                    value: _noClean,
                    onChanged: (value) => setState(() => _noClean = value),
                  ),
                  for (final range in _history!)
                    TrackHistoryRange(
                      key: ValueKey(range.id),
                      draft: range,
                      trackUnit: _unit.trim(),
                      onRemove: () => setState(() => _history!.remove(range)),
                    ),
                  TextButton(
                    key: const ValueKey('track-add-history'),
                    onPressed: _addRange,
                    child: Text(text('AddRange')),
                  ),
                  TextButton(
                    key: const ValueKey('track-add-daily'),
                    onPressed: () => _addRange(daily: true),
                    child: Text(text('AddDaily')),
                  ),
                ]),
                if (_initial.sources.isNotEmpty)
                  _section(text('Sources'), [
                    for (final source in _initial.sources)
                      Padding(
                        padding: const EdgeInsets.only(bottom: S.x3),
                        child: SelectableText(source, style: F.cap),
                      ),
                  ]),
                const SizedBox(height: S.x8),
              ],
            ),
    );
  }

  Widget _section(String title, List<Widget> children, {bool open = false}) =>
      ExpansionTile(
        key: ValueKey('track-section-$title'),
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: open,
        title: Text(title, style: F.head),
        childrenPadding: const EdgeInsets.only(bottom: S.x3),
        children: children,
      );
}
