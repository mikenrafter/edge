// TracksScreen owns only its loaded view. TracksStore owns definitions and logs;
// source sections retain ownership of linked records.
import 'package:flutter/material.dart';
import '../../data/db.dart';
import '../../data/day_label.dart';
import '../../data/tracks_store.dart';
import '../../tracks/experiment.dart';
import '../../state/clock_format.dart';
import '../ui2.dart';
import 'home_screen.dart' show go;
import 'metric_detail.dart' show detailScaffold;
import 'nutrition_screen.dart';
import 'track_editor.dart';
import 'track_experiment.dart';
import 'track_log.dart';
import 'tracks_text.dart';
import 'wellness_screen.dart';
import 'workout_screen.dart';

class TracksScreen extends StatefulWidget {
  const TracksScreen({super.key, this.store});
  final TracksStore? store;
  @override
  State<TracksScreen> createState() => _TracksScreenState();
}

class _TracksScreenState extends State<TracksScreen> {
  TracksStore? _store;
  List<TrackDefinition>? _tracks;
  Map<String, TrackEvent> _lastEvents = const {};
  Map<String, Map<String, Object?>> _learning = const {};
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _failed = false);
    try {
      final store = widget.store ?? TracksStore(await LocalDb.instance);
      final learning = await store.refreshLearning();
      final tracks = await store.definitions();
      final events = await store.lastEvents();
      if (!mounted) return;
      setState(() {
        _store = store;
        _tracks = tracks;
        _learning = learning;
        _lastEvents = events;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _create() async {
    final store = _store;
    if (store == null) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TrackEditor(store: store)));
    if (mounted) await _load();
  }

  Future<void> _open(TrackDefinition track) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TrackDetailScreen(store: _store!, track: track),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    return detailScaffold(context, text('Title'), [
      Text(text('Subtitle'), style: F.head),
      const SizedBox(height: S.x3),
      Text(text('Learning'), style: F.cap),
      const SizedBox(height: S.x3),
      if (_failed) ...[
        Text(text('Failed')),
        TextButton(onPressed: _load, child: Text(text('Retry'))),
      ] else if (_tracks == null)
        const Center(child: CircularProgressIndicator()),
      if (_store != null)
        Wrap(
          spacing: S.x2,
          children: [
            FilledButton.icon(
              key: const ValueKey('tracks-quick-log'),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TrackLogScreen(store: _store),
                  ),
                );
                if (mounted) await _load();
              },
              icon: const Icon(Icons.add),
              label: Text(text('QuickLog')),
            ),
            OutlinedButton(onPressed: _create, child: Text(text('Create'))),
          ],
        ),
      const SizedBox(height: S.x3),
      for (final track in _tracks ?? <TrackDefinition>[]) ...[
        _TrackCard(
          track: track,
          last: _lastEvents[track.id],
          learning: _learning[track.id],
          onTap: () => _open(track),
        ),
        const SizedBox(height: S.x2),
      ],
      const SizedBox(height: S.x3),
      Text(text('Sections'), style: F.head),
      Wrap(
        spacing: S.x2,
        children: [
          TextButton(
            onPressed: () => go(context, const WorkoutScreen()),
            child: Text(text('Workouts')),
          ),
          TextButton(
            onPressed: () => go(
              context,
              const WellnessScreen(initialTab: WellnessScreen.medsTab),
            ),
            child: Text(text('Meds')),
          ),
          TextButton(
            onPressed: () => go(context, const NutritionScreen(page: true)),
            child: Text(text('Nutrition')),
          ),
          TextButton(
            onPressed: () => go(context, const WellnessScreen(initialTab: 0)),
            child: Text(text('Wellness')),
          ),
        ],
      ),
    ]);
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.track,
    this.last,
    this.learning,
    required this.onTap,
  });
  final Map<String, Object?>? learning;
  final TrackDefinition track;
  final TrackEvent? last;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Surface(
    child: InkWell(
      key: ValueKey('track-card-${track.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(S.x1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                trackIcon(track.icon),
                const SizedBox(width: S.x2),
                Expanded(child: Text(track.name, style: F.head)),
                if (!track.enabled)
                  Text(tracksText(context, 'Disabled'), style: F.cap),
                const Icon(Icons.chevron_right),
              ],
            ),
            const SizedBox(height: S.x1),
            Wrap(
              spacing: S.x2,
              children: [
                for (final role in track.roles)
                  Text(
                    tracksText(context, trackRoleLabels[role] ?? role),
                    style: F.cap,
                  ),
              ],
            ),
            Text(
              trackLearningText(context, learning?['reason'] as String?),
              style: F.cap,
            ),
            Text(
              last == null
                  ? tracksText(context, 'Never')
                  : '${tracksText(context, 'Last')}: ${trackEventText(context, last!, track.unit)}',
              style: F.cap,
            ),
          ],
        ),
      ),
    ),
  );
}

Widget trackIcon(String icon) {
  final glyph = <String, IconData>{
    'coffee': Icons.coffee,
    'wine': Icons.wine_bar,
    'leaf': Icons.eco,
    'smoke': Icons.smoking_rooms,
    'meal': Icons.restaurant,
    'workout': Icons.fitness_center,
    'heat': Icons.wb_sunny,
    'cold': Icons.ac_unit,
    'sleep': Icons.bedtime,
    'travel': Icons.flight,
    'health': Icons.health_and_safety,
    'pill': Icons.medication,
    'mind': Icons.self_improvement,
    'water': Icons.water_drop,
    'screen': Icons.devices,
    'cycle': Icons.calendar_month,
    'track': Icons.tune,
  }[icon];
  return glyph == null ? Text(icon, style: F.head) : Icon(glyph, size: 22);
}

String trackEventText(BuildContext context, TrackEvent event, String unit) {
  final at = event.atMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(event.atMs!);
  final time = at == null ? tracksText(context, 'Untimed') : formatClockOf(at);
  final amount = event.amount == null
      ? '—'
      : '${event.amount} ${event.unit ?? unit}'.trim();
  return '${event.date} · $time · $amount';
}

class TrackDetailScreen extends StatefulWidget {
  const TrackDetailScreen({
    super.key,
    required this.store,
    required this.track,
  });
  final TracksStore store;
  final TrackDefinition track;
  @override
  State<TrackDetailScreen> createState() => _TrackDetailScreenState();
}

class _TrackDetailScreenState extends State<TrackDetailScreen> {
  late TrackDefinition _track = widget.track;
  List<TrackEvent>? _events;
  Map<String, Object?>? _learning;
  Map<String, Object?>? _experiment;
  bool _experimentRunning = false;
  bool _failed = false, _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final learning = await widget.store.refreshLearning();
      final events = await widget.store.events(trackId: _track.id);
      final definition = (await widget.store.definitions()).firstWhere(
        (d) => d.id == _track.id,
      );
      final experiments = await widget.store.experiments(trackId: _track.id);
      final latest = experiments.isEmpty ? null : experiments.last;
      final running = latest != null &&
          (await widget.store.experimentReport(latest['id'] as String))['status'] ==
              'running';
      if (mounted) {
        setState(() {
          _experiment = latest;
          _experimentRunning = running;
          _events = events;
          _track = definition;
          _learning = learning[_track.id];
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _edit() async {
    final edited = await Navigator.of(context).push<TrackDefinition>(
      MaterialPageRoute(
        builder: (_) => TrackEditor(store: widget.store, initial: _track),
      ),
    );
    if (edited != null && mounted) setState(() => _track = edited);
    if (mounted) await _load();
  }

  Future<void> _experimentStart() async {
    final experimentable = ExperimentableTrack.from(_track);
    if (experimentable == null) return;
    final started = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            ExperimentSetupScreen(store: widget.store, track: experimentable),
      ),
    );
    if (started == true && mounted) await _load();
  }

  Future<void> _experimentOpen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExperimentScreen(
          store: widget.store,
          track: _track,
          experimentId: _experiment!['id'] as String,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _remove(TrackEvent event) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.store.deleteEvent(event);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    return detailScaffold(context, _track.name, [
      Text(
        trackLearningText(context, _learning?['reason'] as String?),
        key: const ValueKey('track-learning-status'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(text('LogEveryTime')),
        value: _track.loggingComplete,
        onChanged: _busy
            ? null
            : (value) async {
                setState(() => _busy = true);
                try {
                  final updated = TrackDefinition.fromJson({
                    ..._track.toJson(),
                    'logging_complete': value,
                    'logging_complete_since_ms': value
                        ? DateTime.now().millisecondsSinceEpoch
                        : null,
                  });
                  await widget.store.saveDefinition(updated);
                  if (mounted) setState(() => _track = updated);
                  await _load();
                } catch (_) {
                  if (mounted) setState(() => _failed = true);
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
      ),
      TextButton(
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.store.confirmNone(_track.id, todayLabel());
                  await _load();
                } catch (_) {
                  if (mounted) setState(() => _failed = true);
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: Text(text('NoneToday')),
      ),
      Wrap(
        spacing: S.x2,
        children: [
          FilledButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      TrackLogScreen(store: widget.store, track: _track),
                ),
              );
              if (mounted) await _load();
            },
            child: Text(text('QuickLog')),
          ),
          OutlinedButton(onPressed: _edit, child: Text(text('Edit'))),
        ],
      ),
      Wrap(
        spacing: S.x2,
        children: [
          if (_experiment != null && _experimentRunning)
            OutlinedButton(
              onPressed: _experimentOpen,
              child: Text(text('ExperimentView')),
            )
          else ...[
            // ↳ CLAIM(no-med-experiment): no start button for a medication.
            if (ExperimentableTrack.from(_track) != null)
              OutlinedButton(
                onPressed: _experimentStart,
                child: Text(text('ExperimentStart')),
              ),
            if (_experiment != null)
              TextButton(
                onPressed: _experimentOpen,
                child: Text(text('ExperimentViewLast')),
              ),
          ],
        ],
      ),
      const SizedBox(height: S.x3),
      Text(text('Events'), style: F.head),
      if (_failed) ...[
        Text(text('Failed')),
        TextButton(onPressed: _load, child: Text(text('Retry'))),
      ] else if (_events == null)
        const Center(child: CircularProgressIndicator())
      else if (_events!.isEmpty)
        Text(text('Never')),
      for (final event in _events ?? <TrackEvent>[])
        ListTile(
          key: ValueKey('track-event-${event.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text(trackEventText(context, event, _track.unit)),
          subtitle: event.subActivityId == null
              ? null
              : Text(_subName(event.subActivityId!)),
          trailing: IconButton(
            tooltip: text('Remove'),
            onPressed: _busy ? null : () => _remove(event),
            icon: const Icon(Icons.delete_outline),
          ),
        ),
    ]);
  }

  String _subName(String id) {
    for (final sub in _track.subActivities) {
      if (sub.id == id) return sub.name;
    }
    return id;
  }
}
