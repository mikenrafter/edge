// TrackLogScreen owns one draft. A stable submission id makes retries idempotent;
// TracksStore routes linked logs to the source record's owner.
import 'package:flutter/material.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/tracks_store.dart';
import '../../state/clock_format.dart';
import '../ui2.dart';
import 'track_editor_fields.dart' show trackNumber;
import 'tracks_text.dart';

class TrackLogScreen extends StatefulWidget {
  const TrackLogScreen({
    super.key,
    this.store,
    this.track,
    this.date,
    this.initialAt,
  });
  final TracksStore? store;
  final TrackDefinition? track;
  final String? date;
  final DateTime? initialAt;
  @override
  State<TrackLogScreen> createState() => _TrackLogScreenState();
}

class _TrackLogScreenState extends State<TrackLogScreen> {
  late final _id = 'track-log:${DateTime.now().microsecondsSinceEpoch}';
  late String _date =
      widget.date ?? dayLabelOf(widget.initialAt ?? DateTime.now());
  late TimeOfDay _time = TimeOfDay.fromDateTime(
    widget.initialAt ?? DateTime.now(),
  );
  TracksStore? _store;
  List<TrackDefinition>? _tracks;
  TrackDefinition? _track;
  String? _sub, _error;
  String _amount = '';
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = widget.store ?? TracksStore(await LocalDb.instance);
      final definitions = await store.definitions(enabledOnly: true);
      final initial = widget.track;
      if (initial != null && !definitions.any((d) => d.id == initial.id)) {
        definitions.add(initial);
      }
      if (!mounted) return;
      setState(() {
        _store = store;
        _tracks = definitions;
        _track = initial ?? (definitions.isEmpty ? null : definitions.first);
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_date),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked != null && mounted) setState(() => _date = dayLabelOf(picked));
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) setState(() => _time = picked);
  }

  Future<void> _save() async {
    final track = _track, store = _store;
    if (_saving || track == null || store == null) return;
    double? amount;
    try {
      amount = trackNumber(_amount);
    } on FormatException {
      setState(() => _error = 'Invalid');
      return;
    }
    if (['late_workout', 'naps'].contains(track.id) &&
        (amount == null || amount <= 0)) {
      setState(() => _error = 'DurationRequired');
      return;
    }
    final day = DateTime.parse(_date);
    final at = DateTime(day.year, day.month, day.day, _time.hour, _time.minute);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await store.log(
        TrackEvent(
          id: _id,
          trackId: track.id,
          date: _date,
          atMs: at.millisecondsSinceEpoch,
          amount: amount,
          subActivityId: _sub,
          unit: ['late_workout', 'naps'].contains(track.id) ? 'minutes' : null,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    final track = _track;
    return Scaffold(
      backgroundColor: P.of(context).bg,
      appBar: AppBar(title: Text(text('QuickLog'))),
      body: ListView(
        padding: const EdgeInsets.all(S.x4),
        children: [
          if (_error != null)
            Text(text(_error!), key: const ValueKey('track-log-error')),
          if (_tracks == null) ...[
            if (_error == null)
              const Center(child: CircularProgressIndicator())
            else
              TextButton(onPressed: _load, child: Text(text('Retry'))),
          ] else if (_tracks!.isEmpty)
            Text(text('Create'))
          else ...[
            DropdownButtonFormField<String>(
              key: const ValueKey('track-log-track'),
              isExpanded: true,
              initialValue: track?.id,
              decoration: InputDecoration(labelText: text('Title')),
              items: [
                for (final item in _tracks!)
                  DropdownMenuItem(value: item.id, child: Text(item.name)),
              ],
              onChanged: _saving
                  ? null
                  : (id) => setState(() {
                      _track = _tracks!.firstWhere((d) => d.id == id);
                      _sub = null;
                    }),
            ),
            const SizedBox(height: S.x3),
            TextFormField(
              key: const ValueKey('track-log-amount'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: text(
                  ['late_workout', 'naps'].contains(track?.id)
                      ? 'Duration'
                      : 'Amount',
                ),
                helperText:
                    ['late_workout', 'naps'].contains(track?.id) ||
                        track?.unit.isEmpty == true
                    ? null
                    : track?.unit,
              ),
              onChanged: (value) => _amount = value,
            ),
            const SizedBox(height: S.x3),
            if (track != null && track.subActivities.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey('track-log-sub-${track.id}'),
                initialValue: _sub,
                decoration: InputDecoration(labelText: text('Subactivity')),
                items: [
                  DropdownMenuItem(value: null, child: Text(text('None'))),
                  for (final sub in track.subActivities)
                    DropdownMenuItem(value: sub.id, child: Text(sub.name)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _sub = value),
              ),
            const SizedBox(height: S.x3),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(text('Date')),
              trailing: Text(_date),
              onTap: _saving ? null : _pickDate,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(text('Time')),
              trailing: Text(formatClock(_time.hour, _time.minute)),
              onTap: _saving ? null : _pickTime,
            ),
            const SizedBox(height: S.x4),
            FilledButton(
              key: const ValueKey('track-log-save'),
              onPressed: _saving ? null : _save,
              child: Text(text('Save')),
            ),
          ],
        ],
      ),
    );
  }
}

/// Screens refresh their own loaded view after a successful persisted log.
abstract interface class TrackLogObserver {
  Future<void> trackLogged();
}

/// Home and the journal use the same persisted timed logger.
class TrackQuickLog extends StatelessWidget {
  const TrackQuickLog({super.key, this.date, this.observer});
  final String? date;
  final TrackLogObserver? observer;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('track-quick-log'),
    icon: const Icon(Icons.add_circle_outline),
    label: Text(tracksText(context, 'QuickLog')),
    onPressed: () async {
      final logged = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => TrackLogScreen(date: date)),
      );
      if (logged == true && context.mounted) {
        await observer?.trackLogged();
      }
    },
  );
}
