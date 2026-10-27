// Typical day owns its editable meal-clock draft. Persisted settings are owned
// by TypicalMealTimes; all dated comparison work runs in its registered worker.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../data/typical_day_model.dart';
import '../../data/typical_day_source.dart';
import '../../l10n/app_localizations.dart';
import '../../notify/notification_prefs.dart';
import '../../sync/high_freq_wake_window.dart' show loadSavedExpectedSleepSchedule;
import '../profile/alarm.dart';
import '../ui2.dart';
import 'circadian_detail.dart';
import 'home_screen.dart';
import 'metric_detail.dart' show detailScaffold;

class TypicalDayData {
  const TypicalDayData({this.circadian = const CircadianData(), this.quiet,
    this.sleep, this.meals = const [], this.caffeine = const CaffeineTimingSummary()});
  final CircadianData circadian;
  final ClockWindow? quiet, sleep;
  final List<int> meals;
  final CaffeineTimingSummary caffeine;
}

class TypicalDayScreen extends StatefulWidget {
  const TypicalDayScreen({super.key, this.data});
  final TypicalDayData? data;
  @override
  State<TypicalDayScreen> createState() => _TypicalDayScreenState();
}

class _TypicalDayScreenState extends State<TypicalDayScreen> {
  TypicalDayData? _data;
  bool _failed = false, _saving = false;
  @override
  void initState() {
    super.initState();
    _data = widget.data;
    if (_data == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }
  Future<void> _load() async {
    if (mounted) setState(() => _failed = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      final quiet = await NotificationPrefs.load();
      final schedule = loadSavedExpectedSleepSchedule(prefs);
      final meals = await TypicalMealTimes.load();
      if (!mounted) return;
      final repo = repoOf(context);
      if (repo == null) throw StateError('Typical day repository unavailable');
      final warmer = context.read<AppState?>();
      Map<String, dynamic>? last;
      final art = await LastResultCache.instance.loadWarmed<Map<String, dynamic>>(
        'circadian', signature: () => repo.artifactSignature('circadian'),
        warm: () => warmer?.requestWarm('circadian') ?? Future<void>.value(),
        onLast: (hit) => last = hit.value);
      if (!mounted) return;
      final caffeine = await loadTypicalCaffeine(repo);
      if (!mounted) return;
      setState(() => _data = TypicalDayData(
        circadian: art == null && last == null ? const CircadianData()
          : CircadianData.fromArtifact(art ?? last!),
        quiet: quiet.quietEnabled ? ClockWindow(quiet.quietStartMin, quiet.quietEndMin) : null,
        sleep: schedule == null ? null : ClockWindow(schedule.onsetMinute, schedule.wakeMinute),
        meals: _data?.meals ?? meals, caffeine: caffeine));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }
  Future<void> _editMeals() async {
    final d = _data;
    if (d == null || _saving) return;
    final times = await Navigator.of(context).push<List<int>>(MaterialPageRoute(
      builder: (_) => _MealTimesEditor(initial: d.meals)));
    if (times == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await TypicalMealTimes.save(times);
      if (!mounted) return;
      setState(() => _data = TypicalDayData(circadian: d.circadian, quiet: d.quiet,
        sleep: d.sleep, meals: times, caffeine: d.caffeine));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)?.typicalSaveFailed ?? 'Could not save. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final d = _data;
    return detailScaffold(context, l?.typicalDayTitle ?? 'Typical day', [
      if (_failed) ...[
        Text(l?.typicalLoadFailed ?? 'Could not read your day. Try again.'),
        TextButton(onPressed: _load, child: Text(l?.typicalRetry ?? 'Try again')),
      ] else if (d == null) const Center(child: CircularProgressIndicator())
      else ...[
        TextButton(onPressed: () => go(context, const AlarmScreen()),
          child: Text(l?.alarmNavTitle ?? 'Alarm')),
        Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l?.typicalEnergy ?? 'Energy / alertness', style: F.head),
          if (d.circadian.chronotypeLabel.isNotEmpty) Text(d.circadian.chronotypeLabel),
          const SizedBox(height: S.x3),
          TypicalDayPlot(data: d),
          Text(l?.typicalForecastNote ?? 'A shape forecast from your observed sleep and body clock. Unavailable hours stay blank; it is not an energy measurement.', style: F.cap),
          if (d.circadian.alertness.value != null && d.circadian.cosinorV['acrophase_hours'] == null)
            Text(l?.circadianDetailAssumedPhaseNote ?? 'Your own clock peak is not worked out yet, so this uses an average one.'),
          if (d.circadian.alertness.value == null)
            Text(l?.typicalNoCurve ?? 'Not enough recent sleep data for a curve.'),
          const SizedBox(height: S.x3),
          Text('${l?.typicalQuiet ?? 'Quiet hours'}: ${_window(d.quiet)}'),
          Text('${l?.typicalSleep ?? 'Expected sleep'}: ${_window(d.sleep)}'),
        ])),
        const SizedBox(height: S.x3),
        Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l?.typicalMeals ?? 'Typical large meals', style: F.head),
          Text(d.meals.isEmpty ? (l?.typicalNoneSet ?? 'None set') : d.meals.map(clock).join(' · ')),
          TextButton(onPressed: _saving ? null : _editMeals,
            child: Text(l?.typicalEditMeals ?? 'Edit meal times')),
        ])),
        const SizedBox(height: S.x3),
        _caffeine(context, d.caffeine),
      ],
    ]);
  }
  String _window(ClockWindow? w) => w == null ? '—' : '${clock(w.startMinute)}–${clock(w.endMinute)}';

  Widget _caffeine(BuildContext context, CaffeineTimingSummary s) {
    final l = AppLocalizations.of(context);
    final comparisons = <(String, String, double?)>[
      ('dip', l?.typicalDip ?? 'Wake → first caffeine / predicted afternoon dip', s.wakeDelayVsDip),
      ('nap', l?.typicalNaps ?? 'Wake → first caffeine / recorded nap minutes', s.wakeDelayVsNap),
      ('rhr', l?.typicalRhr ?? 'Wake → first caffeine / resting HR', s.wakeDelayVsRestingHr),
      ('latency', l?.typicalLatency ?? 'Bedtime caffeine / sleep latency', s.residualVsLatency),
      ('sleep', l?.typicalTst ?? 'Bedtime caffeine / total sleep', s.residualVsTotalSleep),
    ];
    return Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l?.typicalCaffeine ?? 'Caffeine timing', style: F.head),
      Text(l?.typicalPattern(s.dayCount) ?? 'Your pattern so far, ${s.dayCount} days'),
      const SizedBox(height: S.x2),
      Text(l?.typicalCaffeineLimits ?? 'First recorded caffeine only. Each comparison needs 14 paired days with variation. Associations do not show causes. Missing observations stay blank.'),
      for (final row in comparisons) Padding(padding: const EdgeInsets.symmetric(vertical: S.x1),
        child: Text('${row.$2}: ${row.$3 == null ? '—' : 'ρ = ${row.$3!.toStringAsFixed(2)}'} · n = ${s.pairedCounts[row.$1] ?? 0}')),
      if (!s.enoughDays) Text(l?.typicalTooFew ?? 'Too few recorded days to compare yet.'),
      Text(l?.typicalResidual(s.latestResidualMg?.toStringAsFixed(1) ?? '—') ??
          'Latest bedtime residual from recorded doses: ${s.latestResidualMg?.toStringAsFixed(1) ?? '—'} mg'),
      Text(l?.typicalDoseLimits ?? 'A model with a 5 h half-life, not a measurement. Old daily totals cannot identify individual doses; incomplete dose records cannot estimate a residual. The predicted dip uses sleep only; caffeine does not change the forecast.', style: F.cap),
    ]));
  }
}

class _MealTimesEditor extends StatefulWidget {
  const _MealTimesEditor({required this.initial});
  final List<int> initial;
  @override
  State<_MealTimesEditor> createState() => _MealTimesEditorState();
}
class _MealTimesEditorState extends State<_MealTimesEditor> {
  late final List<int> _times = [...widget.initial];
  Future<void> _pick([int? index]) async {
    final minute = index == null ? 12 * 60 : _times[index];
    final chosen = await showTimePicker(context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60));
    if (chosen == null || !mounted) return;
    setState(() {
      if (index != null) _times.removeAt(index);
      final value = chosen.hour * 60 + chosen.minute;
      if (!_times.contains(value)) _times.add(value);
      _times.sort();
    });
  }
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(l?.typicalMeals ?? 'Typical large meals')),
      body: ListView(children: [
        for (var i = 0; i < _times.length; i++) ListTile(
          title: Text(clock(_times[i])), onTap: () => _pick(i),
          trailing: IconButton(tooltip: l?.typicalRemove ?? 'Remove', icon: const Icon(Icons.close),
            onPressed: () => setState(() => _times.removeAt(i)))),
        TextButton(onPressed: _pick, child: Text(l?.typicalAddTime ?? 'Add time')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_times),
          child: Text(l?.typicalSave ?? 'Save')),
      ]));
  }
}

/// Three clock lanes share the forecast's midnight-to-midnight x-axis. Sleep
/// and quiet windows split at midnight; unsupported curve hours are unpainted.
class TypicalDayPlot extends StatelessWidget {
  const TypicalDayPlot({super.key, required this.data});
  final TypicalDayData data;
  @override
  Widget build(BuildContext context) => Column(children: [
    RepaintBoundary(child: SizedBox(height: 160, width: double.infinity,
      child: CustomPaint(painter: _TypicalPainter(data, Theme.of(context).colorScheme.primary)))),
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [for (final h in [0, 6, 12, 18, 24]) Text(h == 24 ? '24:00' : clock(h * 60), style: F.cap)]),
  ]);
}
class _TypicalPainter extends CustomPainter {
  const _TypicalPainter(this.data, this.color);
  final TypicalDayData data;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 2;
    final forecast = data.circadian.alertness.value;
    if (forecast != null && forecast.shape.length > 1) {
      final shape = forecast.shape;
      final lo = shape.reduce((a,b) => a < b ? a : b);
      final hi = shape.reduce((a,b) => a > b ? a : b);
      Offset? previous;
      for (var i = 0; i < shape.length; i++) {
        final hour = (forecast.startHour + 18 * i / (shape.length - 1)) % 24;
        final y = hi == lo ? 50.0 : 90 - 80 * (shape[i] - lo) / (hi - lo);
        final point = Offset(size.width * hour / 24, y);
        if (previous != null && point.dx >= previous.dx) canvas.drawLine(previous, point, paint);
        previous = point;
      }
    }
    void lane(ClockWindow? window, double top, double alpha) {
      if (window == null) return;
      paint.color = color.withValues(alpha: alpha);
      for (final span in window.segments) {
        canvas.drawRect(Rect.fromLTRB(size.width * span.$1 / 1440, top,
          size.width * span.$2 / 1440, top + 12), paint);
      }
    }
    lane(data.quiet, 108, .25);
    lane(data.sleep, 126, .6);
    paint.color = color;
    for (final minute in data.meals) {
      final x = size.width * minute / 1440;
      canvas.drawLine(Offset(x, 145), Offset(x, 158), paint);
    }
  }
  @override
  bool shouldRepaint(_TypicalPainter old) => old.data != data || old.color != color;
}
