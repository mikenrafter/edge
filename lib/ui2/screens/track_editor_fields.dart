// Each editor owns these drafts until a single TracksStore transaction saves it.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../data/day_label.dart';
import '../../data/tracks_store.dart';
import '../ui2.dart';
import 'tracks_text.dart';

class TrackKineticsDraft {
  TrackKineticsDraft(TrackKinetics initial)
    : values = {
        for (final k in {...trackKineticKeys, ...initial.fields.keys})
          k: initial.fields[k]?.value?.toString() ?? '',
      },
      locks = {
        for (final k in {...trackKineticKeys, ...initial.fields.keys})
          k: initial.fields[k]?.locked ?? false,
      };
  final Map<String, String> values;
  final Map<String, bool> locks;
  TrackKinetics read() => TrackKinetics({
    for (final key in values.keys)
      key: TrackKineticField(
        value: trackNumber(values[key]!),
        locked: locks[key] ?? false,
      ),
  });
}

double? trackNumber(String text) {
  if (text.trim().isEmpty) return null;
  final value = double.tryParse(text.trim().replaceAll(',', '.'));
  if (value == null || !value.isFinite || value < 0) {
    throw const FormatException('number');
  }
  return value;
}

class TrackKineticsFields extends StatefulWidget {
  const TrackKineticsFields({
    super.key,
    required this.draft,
    this.prefix = 'kinetics',
  });
  final TrackKineticsDraft draft;
  final String prefix;
  @override
  State<TrackKineticsFields> createState() => _TrackKineticsFieldsState();
}

class _TrackKineticsFieldsState extends State<TrackKineticsFields> {
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final field in widget.draft.values.keys)
        Padding(
          padding: const EdgeInsets.only(bottom: S.x3),
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('${widget.prefix}-$field'),
                  initialValue: widget.draft.values[field],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tracksText(
                      context,
                      trackKineticLabels[field] ?? field,
                    ),
                  ),
                  onChanged: (value) => widget.draft.values[field] = value,
                ),
              ),
              const SizedBox(width: S.x2),
              IconButton(
                key: ValueKey('${widget.prefix}-$field-lock'),
                tooltip: tracksText(
                  context,
                  widget.draft.locks[field] == true ? 'Unlock' : 'Lock',
                ),
                isSelected: widget.draft.locks[field] ?? false,
                icon: const Icon(Icons.lock_open),
                selectedIcon: const Icon(Icons.lock),
                onPressed: () => setState(
                  () => widget.draft.locks[field] =
                      !(widget.draft.locks[field] ?? false),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class TrackSubDraft {
  TrackSubDraft(TrackSubActivity initial)
    : id = initial.id,
      name = initial.name,
      kinetics = TrackKineticsDraft(initial.kinetics);
  final String id;
  String name;
  final TrackKineticsDraft kinetics;
  TrackSubActivity read() =>
      TrackSubActivity(id: id, name: name.trim(), kinetics: kinetics.read());
}

/// The editor's unsaved copy of one setup period. A done period may carry a
/// time, an amount and no end; a not-done one never does, so [read] builds the
/// sealed [TrackSetupRange] that matches the selection and drops the rest
/// (CLAIM(range-invariants)).
class TrackRangeDraft {
  TrackRangeDraft(TrackSetupRange range)
    : id = range.id,
      start = range.startDate,
      done = range.done,
      ongoing = range is DoneRange && range.ongoing,
      end = range is DoneRange && range.ongoing ? range.startDate : range.endDate {
    if (range is DoneRange) {
      final minute = range.intake.approxMinute;
      if (minute != null) around = trackMinuteText(minute);
      final amount = range.intake.amount;
      if (amount != null) {
        this.amount = trackAmountText(amount.value);
        _enteredAmount = this.amount;
        _enteredUnit = amount.unit;
      }
    }
  }
  final String id;
  String start, end, around = '', amount = '';
  bool done, ongoing;
  String _enteredAmount = '';
  String? _enteredUnit;

  /// The amount's unit: the one it was entered in when untouched, else the
  /// track's current unit.
  String unitFor(String trackUnit) =>
      _enteredUnit != null && amount == _enteredAmount ? _enteredUnit! : trackUnit;

  /// ArgumentError for a time that is not HH:mm or an amount that is not a
  /// positive number; the editor reports it as invalid and keeps the form.
  TrackSetupRange read(String trackId, String trackUnit) {
    if (!done) {
      return NotDoneRange(
        id: id,
        trackId: trackId,
        startDate: start,
        endDate: end,
      );
    }
    final minute = around.trim().isEmpty ? null : trackParseMinute(around);
    final value = amount.trim().isEmpty
        ? null
        : double.tryParse(amount.trim().replaceAll(',', '.'));
    if ((around.trim().isNotEmpty && minute == null) ||
        (amount.trim().isNotEmpty &&
            (value == null || !value.isFinite || value <= 0))) {
      throw ArgumentError('history');
    }
    return DoneRange(
      id: id,
      trackId: trackId,
      startDate: start,
      untilDate: ongoing ? null : end,
      intake: DailyIntake(
        approxMinute: minute,
        amount: value == null ? null : DailyAmount(value, unitFor(trackUnit)),
      ),
    );
  }
}

/// 480 -> "08:00".
String trackMinuteText(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

/// "8:05" / "08:05" -> 485; null when it is not a 24 h time.
int? trackParseMinute(String text) {
  final match = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(text.trim());
  return match == null
      ? null
      : int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

/// 50.0 -> "50", 2.5 -> "2.5".
String trackAmountText(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : value.toString();

class TrackHistoryRange extends StatefulWidget {
  const TrackHistoryRange({
    super.key,
    required this.draft,
    required this.trackUnit,
    required this.onRemove,
  });
  final TrackRangeDraft draft;

  /// The track's unit as currently typed in the editor.
  final String trackUnit;
  final VoidCallback onRemove;
  @override
  State<TrackHistoryRange> createState() => _TrackHistoryRangeState();
}

class _TrackHistoryRangeState extends State<TrackHistoryRange> {
  Future<void> _pick(bool start) async {
    final draft = widget.draft;
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(start ? draft.start : draft.end),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (date == null || !mounted) return;
    setState(() {
      if (start) {
        draft.start = dayLabelOf(date);
      } else {
        draft.end = dayLabelOf(date);
        draft.ongoing = false;
      }
    });
  }

  String _day(String label) {
    final locale = Localizations.localeOf(context).toString();
    final day = DateTime.parse(label);
    return (day.year == clock.now().year
            ? DateFormat.MMMd(locale)
            : DateFormat.yMMMd(locale))
        .format(day);
  }

  /// "Daily since Mar 1 \u00b7 ~08:00 \u00b7 50 mg", from the draft as typed.
  String _summary() {
    final draft = widget.draft;
    final title = tracksPeriodTitle(
      context,
      done: draft.done,
      from: _day(draft.start),
      to: draft.done && draft.ongoing ? null : _day(draft.end),
    );
    if (!draft.done) return title;
    final minute = trackParseMinute(draft.around);
    final value = double.tryParse(draft.amount.trim().replaceAll(',', '.'));
    final unit = draft.unitFor(widget.trackUnit);
    return [
      title,
      if (minute != null) '~${trackMinuteText(minute)}',
      if (value != null && value.isFinite && value > 0)
        unit.isEmpty ? trackAmountText(value) : '${trackAmountText(value)} $unit',
    ].join(' \u00b7 ');
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_summary(), key: ValueKey('history-${draft.id}-summary')),
          Wrap(
            spacing: S.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                key: ValueKey('history-${draft.id}-start'),
                onPressed: () => _pick(true),
                child: Text('${tracksText(context, 'From')}: ${draft.start}'),
              ),
              TextButton(
                key: ValueKey('history-${draft.id}-end'),
                onPressed: () => _pick(false),
                child: Text(
                  '${tracksText(context, 'Until')}: '
                  '${draft.done && draft.ongoing ? tracksText(context, 'OngoingShort') : draft.end}',
                ),
              ),
              IconButton(
                tooltip: tracksText(context, 'Remove'),
                onPressed: widget.onRemove,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: true,
                label: Text(tracksText(context, 'Done')),
              ),
              ButtonSegment(
                value: false,
                label: Text(tracksText(context, 'NotDone')),
              ),
            ],
            selected: {draft.done},
            onSelectionChanged: (values) =>
                setState(() => draft.done = values.single),
          ),
          if (draft.done) ...[
            SwitchListTile(
              key: ValueKey('history-${draft.id}-ongoing'),
              contentPadding: EdgeInsets.zero,
              title: Text(tracksText(context, 'Ongoing')),
              value: draft.ongoing,
              onChanged: (value) => setState(() => draft.ongoing = value),
            ),
            TextFormField(
              key: ValueKey('history-${draft.id}-around'),
              initialValue: draft.around,
              keyboardType: TextInputType.datetime,
              decoration: InputDecoration(
                labelText: tracksText(context, 'Around'),
              ),
              onChanged: (value) => setState(() => draft.around = value),
            ),
            TextFormField(
              key: ValueKey('history-${draft.id}-amount'),
              initialValue: draft.amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: tracksText(context, 'AmountPerDay'),
                suffixText: draft.unitFor(widget.trackUnit),
              ),
              onChanged: (value) => setState(() => draft.amount = value),
            ),
          ],
        ],
      ),
    );
  }
}
