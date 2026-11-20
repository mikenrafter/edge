import '../data/day_label.dart';
import 'profile/profile.dart' show SetRow;
import 'screens/home_screen.dart' show clockOfTs;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../l10n/date_text.dart' show displayDay;
import '../state/prefs.dart';
import 'personal_day.dart';
import 'ui2.dart';

String personalDayTitle(PersonalDayMode mode, AppLocalizations? l) => switch (mode) {
  PersonalDayMode.wakeToWake => l?.personalDayWake ?? 'Your day (wake to wake)',
  PersonalDayMode.sleepToSleep => l?.personalDaySleep ?? 'Your day (sleep to sleep)',
  PersonalDayMode.calendarOffset => l?.personalDayCalendar ?? 'Calendar days (12 h offset)',
};

/// The day bar's label (owner m301): "Day of <date>", or "Cycle of <date>" when
/// the day runs sleep to sleep. The date is the day the cycle is named for, the
/// one its numbers are read from; the start time is in the caption under it.
String personalDayNavLabel(PersonalDay day, PersonalDayMode mode, [AppLocalizations? l]) {
  final date = displayDay(day.label, l);
  return mode == PersonalDayMode.sleepToSleep
      ? l?.personalCycleOf(date) ?? 'Cycle of $date'
      : l?.personalDayOf(date) ?? 'Day of $date';
}

/// [personalDayNavLabel] for every cycle the bar can step over. Two cycles can
/// be named for the same date (a day that started late, a sleep onset before
/// midnight); a bar that read the same twice would look like a step that did
/// nothing, so only those carry their start time too [owner m301].
Map<String, String> personalDayNavLabels(List<PersonalDay> cycles,
    PersonalDayMode mode, [AppLocalizations? l]) {
  String time(PersonalDay c) => clockOfTs(c.start.millisecondsSinceEpoch ~/ 1000);
  Map<String, String> pass(String Function(PersonalDay, String) name,
      Map<String, String> base) {
    final counts = <String, int>{};
    for (final v in base.values) { counts[v] = (counts[v] ?? 0) + 1; }
    return {for (final c in cycles) c.id.value: counts[base[c.id.value]]! > 1
        ? name(c, base[c.id.value]!) : base[c.id.value]!};
  }
  final names = {for (final c in cycles) c.id.value: personalDayNavLabel(c, mode, l)};
  // First the start time; where that still repeats (the same onset hour on two
  // evenings), the day it started on as well.
  final timed = pass((c, n) => '$n · ${time(c)}', names);
  return pass((c, n) => '${names[c.id.value]} · ${displayDay(dayLabelOf(c.start), l)} ${time(c)}', timed);
}

class PersonalDayCaption extends StatelessWidget {
  const PersonalDayCaption(this.day, this.mode, {super.key});
  final PersonalDay? day;
  final PersonalDayMode mode;
  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return Padding(padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(personalDayTitle(mode, l), style: F.body),
        if (day != null) Text('${dayLabelOf(day!.start)} · ${clockOfTs(day!.start.millisecondsSinceEpoch ~/ 1000)} → '
          '${dayLabelOf(day!.end)} · ${clockOfTs(day!.end.millisecondsSinceEpoch ~/ 1000)}',
          maxLines: 2, style: F.over),
        Text(day?.scoreDay == null ? (l?.personalDayUnknown ?? 'No calendar totals for this day')
          : '${l?.personalDayCalendarNote ?? 'Scores and totals use one calendar day:'} ${day!.scoreDay}',
          style: F.over.copyWith(color: P.of(c).ink3)),
      ]));
  }
}

class PersonalDaySettings extends StatefulWidget {
  const PersonalDaySettings({super.key});
  @override
  State<PersonalDaySettings> createState() => _PersonalDaySettingsState();
}
class _PersonalDaySettingsState extends State<PersonalDaySettings> {
  bool _saving = false;
  void _changed() { if (mounted) setState(() {}); }
  @override
  void initState() { super.initState(); Prefs.personalDayRevision.addListener(_changed); }
  @override
  void dispose() { Prefs.personalDayRevision.removeListener(_changed); super.dispose(); }
  Future<void> _save(Future<bool> Function() write) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await write();
      if (!mounted) return;
      if (!saved) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:
          Text(AppLocalizations.of(context)?.personalDaySaveFailed ?? 'Could not save this setting. Try again.')));
      }
    } finally { if (mounted) setState(() => _saving = false); }
  }
  String _totalsValue(AppLocalizations? l) {
    final name = Prefs.personalDayTotals == PersonalDayTotals.first
        ? (l?.personalDayFirst ?? 'First calendar day') : (l?.personalDayLast ?? 'Last calendar day');
    return !Prefs.personalDayTotalsIsDefault ? name
        : l?.personalDayDefaultValue(name) ?? '$name (default)';
  }
  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return Column(children: [
      SetRow(LucideIcons.sunrise, C.blue, l?.personalDaySetting ?? 'Your day',
        sub: Prefs.personalDayEnabled ? personalDayTitle(Prefs.personalDayMode, l)
          : (l?.personalDayCurrent ?? 'Current behaviour'),
        onTap: _saving ? null : () async {
          final picked = await showModalBottomSheet<({PersonalDayMode? mode})>(context: c,
            builder: (c) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
              children: [
                Padding(padding: const EdgeInsets.all(S.x4), child: Text(l?.personalDayExplain ??
                  'Choose day boundaries for your timeline and history. Home always follows your current day.')),
                ListTile(title: Text(l?.personalDayCurrent ?? 'Current behaviour'),
                  selected: !Prefs.personalDayEnabled,
                  onTap: () => Navigator.pop(c, (mode: null))),
                for (final mode in PersonalDayMode.values)
                ListTile(title: Text(personalDayTitle(mode, l)),
                  selected: Prefs.personalDayEnabled && mode == Prefs.personalDayMode,
                  onTap: () => Navigator.pop(c, (mode: mode)))]))));
          if (picked != null && mounted) {
            final mode = picked.mode;
            await _save(() => mode == null
                ? Prefs.setPersonalDayEnabled(false)
                : Prefs.setPersonalDayMode(mode));
          }
        }),
      SetRow(LucideIcons.calendarDays, C.blue, l?.personalDayTotals ?? 'Daily scores and totals',
        sub: _totalsValue(l),
        onTap: _saving ? null : () => _save(() => Prefs.setPersonalDayTotals(
          Prefs.personalDayTotalsIsDefault ? PersonalDayTotals.first
            : Prefs.personalDayTotals == PersonalDayTotals.first ? PersonalDayTotals.last : null))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
        child: Text(l?.personalDayTotalsExplain ??
          'This calendar day choice applies throughout your timeline and history. The default is chosen from your latest complete cycle when available.',
          style: F.over.copyWith(color: P.of(c).ink3))),
    ]);
  }
}
