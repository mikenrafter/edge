// Each editor owns these drafts until a single TracksStore transaction saves it.
import 'package:flutter/material.dart';
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

class TrackRangeDraft {
  TrackRangeDraft(TrackSetupRange range)
    : id = range.id,
      start = range.startDate,
      end = range.endDate,
      done = range.done;
  final String id;
  String start, end;
  bool done;
  TrackSetupRange read(String trackId) => TrackSetupRange(
    id: id,
    trackId: trackId,
    startDate: start,
    endDate: end,
    done: done,
  );
}

class TrackHistoryRange extends StatefulWidget {
  const TrackHistoryRange({
    super.key,
    required this.draft,
    required this.onRemove,
  });
  final TrackRangeDraft draft;
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
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: S.x3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: S.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: ValueKey('history-${widget.draft.id}-start'),
              onPressed: () => _pick(true),
              child: Text(
                '${tracksText(context, 'From')}: ${widget.draft.start}',
              ),
            ),
            TextButton(
              key: ValueKey('history-${widget.draft.id}-end'),
              onPressed: () => _pick(false),
              child: Text(
                '${tracksText(context, 'Until')}: ${widget.draft.end}',
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
          selected: {widget.draft.done},
          onSelectionChanged: (values) =>
              setState(() => widget.draft.done = values.single),
        ),
      ],
    ),
  );
}
