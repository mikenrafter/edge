// travel_plan_form.dart — the input form for the schedule-based travel plan.
//
// Nothing is invented. The usual sleep and wake times start from the recorded
// means (`meanOnsetClock` and `meanWakeClock` of the summary); with fewer than
// three recorded nights those are null and the person types them. The
// origin zone starts from the phone's zone when the platform can say. The
// destination and the departure date have no default. [plan] does the work and
// is pure; it is cheap, so it runs on the tap.

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../ui2/ui2.dart';
import 'sleep_timing_summary.dart';
import 'travel_schedule_planner.dart';

/// The phone's IANA zone name, or null when it cannot be read.
typedef LocalZoneReader = Future<String?> Function();

Future<String?> _deviceZone() async {
  try {
    return await FlutterTimezone.getLocalTimezone();
  } catch (_) {
    return null; // no plugin (tests, a failing platform call): ask instead
  }
}

class TravelPlanForm extends StatefulWidget {
  const TravelPlanForm({
    super.key,
    required this.summary,
    required this.onPlan,
    this.localZone,
    this.initialDest,
    this.initialDeparture,
  });

  final SleepTimingSummary summary;
  final ValueChanged<TravelPlan> onPlan;

  /// How the phone's zone is read; defaults to flutter_timezone.
  final LocalZoneReader? localZone;

  /// Optional prefills for the two fields that have no default.
  final String? initialDest;
  final DateTime? initialDeparture;

  @override
  State<TravelPlanForm> createState() => _TravelPlanFormState();
}

class _TravelPlanFormState extends State<TravelPlanForm> {
  String? _origin, _dest;
  DateTime? _departure;
  Duration? _usualOnset, _usualWake, _wantOnset, _wantWake;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dest = widget.initialDest;
    _departure = widget.initialDeparture;
    // The recorded means, only when there are any.
    _usualOnset = widget.summary.meanOnsetClock;
    _usualWake = widget.summary.meanWakeClock;
    _readOrigin();
  }

  Future<void> _readOrigin() async {
    final name = await (widget.localZone ?? _deviceZone)();
    if (!mounted || name == null || _origin != null) return;
    if (!_zoneNames().contains(name)) return;
    setState(() => _origin = name);
  }

  List<String> _zoneNames() =>
      tz.timeZoneDatabase.locations.keys.toList()..sort();

  Future<void> _pickZone(bool origin) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: P.of(context).card,
      builder: (_) => _ZoneSheet(names: _zoneNames()),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (origin) {
        _origin = picked;
      } else {
        _dest = picked;
      }
      _error = null;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _departure ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
    );
    if (d == null || !mounted) return;
    setState(() {
      _departure = d;
      _error = null;
    });
  }

  Future<Duration?> _pickTime(Duration? from) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: (from?.inHours ?? 23) % 24, minute: (from?.inMinutes ?? 0) % 60),
    );
    if (t == null) return null;
    return Duration(hours: t.hour, minutes: t.minute);
  }

  void _submit() {
    String? err;
    final onset = _usualOnset, wake = _usualWake;
    final origin = _origin, dest = _dest, dep = _departure;
    if (onset == null || wake == null) {
      err = 'Enter your usual sleep and wake times first. None are guessed.';
    } else if (origin == null || dest == null) {
      err = 'Choose the time zone you leave and the one you arrive in.';
    } else if (dep == null) {
      err = 'Choose a departure date.';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    try {
      final result = plan(TravelInput(
        habitualOnset: onset!,
        habitualWake: wake!,
        originTz: origin!,
        destTz: dest!,
        departureLocalDate: dep!,
        desiredOnset: _wantOnset,
        desiredWake: _wantWake,
      ));
      setState(() => _error = null);
      widget.onPlan(result);
    } on ArgumentError {
      setState(() => _error = 'That time zone is not known to this phone.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final recorded = widget.summary.meanOnsetClock != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Uses only what you enter here, never your body data. The usual '
          'times start from your recorded nights'
          '${recorded ? '' : ' (not enough yet, so enter them)'}.',
          style: F.cap.copyWith(color: p.ink2, height: 1.4),
        ),
        _field(p, 'circadian-form-origin', 'Leaving from', _origin ?? 'Choose',
            () => _pickZone(true)),
        _field(p, 'circadian-form-dest', 'Going to', _dest ?? 'Choose',
            () => _pickZone(false)),
        _field(p, 'circadian-form-date', 'Departure date',
            _departure == null ? 'Choose' : _dateText(_departure!), _pickDate),
        _field(p, 'circadian-form-onset', 'Usual sleep time',
            _usualOnset == null ? 'Required' : _hhmm(_usualOnset!), () async {
          final t = await _pickTime(_usualOnset);
          if (t != null && mounted) setState(() => _usualOnset = t);
        }),
        _field(p, 'circadian-form-wake', 'Usual wake time',
            _usualWake == null ? 'Required' : _hhmm(_usualWake!), () async {
          final t = await _pickTime(_usualWake);
          if (t != null && mounted) setState(() => _usualWake = t);
        }),
        _field(p, 'circadian-form-want-onset', 'Wanted sleep time there',
            _wantOnset == null ? 'Same as usual' : _hhmm(_wantOnset!), () async {
          final t = await _pickTime(_wantOnset ?? _usualOnset);
          if (t != null && mounted) setState(() => _wantOnset = t);
        }),
        _field(p, 'circadian-form-want-wake', 'Wanted wake time there',
            _wantWake == null ? 'Same as usual' : _hhmm(_wantWake!), () async {
          final t = await _pickTime(_wantWake ?? _usualWake);
          if (t != null && mounted) setState(() => _wantWake = t);
        }),
        if (_wantOnset != null || _wantWake != null)
          Align(
            alignment: Alignment.centerRight,
            child: Pressable(
              onTap: () => setState(() => _wantOnset = _wantWake = null),
              semanticLabel: 'Use my usual times there',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x2),
                child: Text('Use my usual times there',
                    style: F.cap.copyWith(color: p.on(C.blue))),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(_error!,
                key: const ValueKey('circadian-form-error'),
                style: F.cap.copyWith(color: p.on(C.red), height: 1.4)),
          ),
        const SizedBox(height: S.x3),
        BigButton(
          'Make travel schedule',
          key: const ValueKey('circadian-form-plan'),
          soft: true,
          color: C.blue,
          onTap: _submit,
        ),
      ],
    );
  }

  Widget _field(
          P p, String key, String label, String value, VoidCallback onTap) =>
      Pressable(
        key: ValueKey(key),
        onTap: onTap,
        semanticLabel: '$label, $value',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text(label, style: F.body.copyWith(color: p.ink))),
              const SizedBox(width: S.x2),
              Flexible(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: F.body.copyWith(color: p.on(C.blue))),
              ),
            ],
          ),
        ),
      );
}

String _hhmm(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours % 24)}:${two(d.inMinutes % 60)}';
}

String _dateText(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// A searchable list of every IANA zone the tz database holds.
class _ZoneSheet extends StatefulWidget {
  const _ZoneSheet({required this.names});
  final List<String> names;

  @override
  State<_ZoneSheet> createState() => _ZoneSheetState();
}

class _ZoneSheetState extends State<_ZoneSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final q = _q.trim().toLowerCase().replaceAll(' ', '_');
    final shown = [
      for (final n in widget.names)
        if (q.isEmpty || n.toLowerCase().contains(q)) n,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(S.x3),
              child: TextField(
                key: const ValueKey('circadian-zone-search'),
                autofocus: true,
                decoration:
                    const InputDecoration(hintText: 'Search, e.g. Europe/London'),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (_, i) => Pressable(
                  onTap: () => Navigator.of(context).pop(shown[i]),
                  semanticLabel: shown[i],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: S.x4, vertical: S.x3),
                    child: Text(shown[i], style: F.body.copyWith(color: p.ink)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
