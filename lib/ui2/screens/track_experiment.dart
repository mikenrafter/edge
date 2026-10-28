// Randomized N-of-1 experiment screens. TracksStore owns assignment, adherence
// and the report; these screens only ask for a length and show what it holds.
import 'package:flutter/material.dart';
import '../../data/day_label.dart';
import '../../data/tracks_store.dart';
import '../../tracks/experiment.dart';
import '../ui2.dart';
import 'metric_detail.dart' show detailScaffold;
import 'tracks_text.dart';

class ExperimentSetupScreen extends StatefulWidget {
  const ExperimentSetupScreen({
    super.key,
    required this.store,
    required this.track,
  });
  final TracksStore store;
  final TrackDefinition track;
  @override
  State<ExperimentSetupScreen> createState() => _ExperimentSetupScreenState();
}

class _ExperimentSetupScreenState extends State<ExperimentSetupScreen> {
  int _weeks = 2;
  bool _busy = false, _failed = false;

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.store.startExperiment(
        trackId: widget.track.id,
        startDate: todayLabel(),
        weeks: _weeks,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    // ↳ CLAIM(never-ask-skip-prescribed): no Begin for a prescribed track.
    if (ExperimentableTrack.from(widget.track) == null) {
      return detailScaffold(context, text('ExperimentSetup'), [
        Text(widget.track.name, style: F.head),
        const SizedBox(height: S.x2),
        Text(
          text('ExperimentPrescribed'),
          key: const ValueKey('experiment-prescribed'),
        ),
      ]);
    }
    final washedOut = experimentWashoutExceedsBlock(widget.track);
    return detailScaffold(context, text('ExperimentSetup'), [
      Text(widget.track.name, style: F.head),
      const SizedBox(height: S.x2),
      Text(text('ExperimentExplain')),
      const SizedBox(height: S.x3),
      Wrap(
        spacing: S.x2,
        children: [
          for (final weeks in const [2, 3, 4])
            ChoiceChip(
              label: Text(experimentWeeksText(context, weeks)),
              selected: _weeks == weeks,
              onSelected: _busy ? null : (_) => setState(() => _weeks = weeks),
            ),
        ],
      ),
      const SizedBox(height: S.x3),
      // ↳ CLAIM(washout-vs-block): say why, and do not offer a biased run.
      if (washedOut) ...[
        Text(
          experimentWashoutText(context, experimentWashoutDays(widget.track)),
          key: const ValueKey('experiment-washout'),
        ),
        const SizedBox(height: S.x3),
      ],
      if (_failed) Text(text('ExperimentFailed')),
      FilledButton(
        onPressed: _busy || washedOut ? null : _begin,
        child: Text(text('ExperimentBegin')),
      ),
    ]);
  }
}

class ExperimentScreen extends StatefulWidget {
  const ExperimentScreen({
    super.key,
    required this.store,
    required this.track,
    required this.experimentId,
  });
  final TracksStore store;
  final TrackDefinition track;
  final String experimentId;
  @override
  State<ExperimentScreen> createState() => _ExperimentScreenState();
}

class _ExperimentScreenState extends State<ExperimentScreen> {
  Map<String, Object?>? _experiment, _report;
  Map<String, bool> _answers = const {};
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await widget.store.experiments(trackId: widget.track.id);
      final experiment = all.firstWhere((e) => e['id'] == widget.experimentId);
      final report = await widget.store.experimentReport(widget.experimentId);
      final answers = await widget.store.experimentAnswers(widget.experimentId);
      if (mounted) {
        setState(() {
          _experiment = experiment;
          _report = report;
          _answers = answers;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  // ↳ CLAIM(backfill-answers)
  Future<void> _answer(String date, bool didIt) async {
    try {
      await widget.store.answerExperimentDay(widget.experimentId, date, didIt: didIt);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _stop() async {
    try {
      await widget.store.stopExperiment(widget.experimentId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    String text(String key) => tracksText(context, key);
    final report = _report, experiment = _experiment;
    final running = report?['status'] == 'running';
    final stopped = report?['status'] == 'stopped';
    final effects = (report?['effects'] as Map? ?? const {}).cast<String, Map>();
    return detailScaffold(context, text('ExperimentTitle'), [
      Text(widget.track.name, style: F.head),
      if (_failed) ...[
        Text(text('Failed')),
        TextButton(onPressed: _load, child: Text(text('Retry'))),
      ] else if (report == null || experiment == null)
        const Center(child: CircularProgressIndicator())
      else ...[
        Text(
          '${running ? text('ExperimentRunning') : stopped ? text('ExperimentStopped') : text('ExperimentCompleted')}'
          ' · ${experiment['start_date']} – ${experiment['end_date']}',
          key: const ValueKey('experiment-status'),
        ),
        const SizedBox(height: S.x2),
        if (running) ...[
          Text(text('ExperimentPending')),
          TextButton(
            key: const ValueKey('experiment-stop'),
            onPressed: _stop,
            child: Text(text('ExperimentStop')),
          ),
        ] else if (stopped)
          Text(text('ExperimentStoppedNote'))
        else ...[
          Text(text('ExperimentEffectHeading'), style: F.head),
          if (report['adherence'] is Map)
            Text(
              experimentAdherenceText(
                context,
                (report['adherence'] as Map)['followed'] as int,
                (report['adherence'] as Map)['assigned'] as int,
              ),
            ),
          if (report['reason'] != null)
            Text(
              text(
                report['reason'] == 'insufficient_adherence'
                    ? 'ExperimentLowAdherence'
                    : 'ExperimentLowData',
              ),
            ),
          // ↳ CLAIM(effects-multiplicity): several intervals, one note.
          if (effects.length > 1)
            Text(
              experimentMultiplicityText(context, effects.length),
              key: const ValueKey('experiment-multiplicity'),
              style: F.cap,
            ),
          for (final entry in effects.entries)
            Text(
              experimentEffectText(
                context,
                entry.key,
                tracksText(context, trackSystemLabels[entry.key] ?? entry.key),
                entry.value,
              ),
            ),
        ],
        const SizedBox(height: S.x3),
        // ↳ CLAIM(never-ask-skip-prescribed): a track that became prescribed
        // after the start shows no do/skip days.
        if (ExperimentableTrack.from(widget.track) == null)
          Text(
            text('ExperimentPrescribed'),
            key: const ValueKey('experiment-prescribed'),
          )
        else
          for (final day in (experiment['assignments'] as List).cast<Map>())
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${day['date']} · '
                  '${day['do'] == true ? text('ExperimentDo') : text('ExperimentSkip')}',
                ),
                // Past and current assigned days can be answered later, while
                // the experiment still runs.
                if (running &&
                    (day['date'] as String).compareTo(
                          report['as_of_date'] as String? ?? todayLabel(),
                        ) <=
                        0)
                  Wrap(
                    spacing: S.x2,
                    children: [
                      ChoiceChip(
                        key: ValueKey('xp-did-${day['date']}'),
                        label: Text(text('ExperimentDid')),
                        selected: _answers[day['date']] == true,
                        onSelected: (_) => _answer(day['date'] as String, true),
                      ),
                      ChoiceChip(
                        key: ValueKey('xp-didnt-${day['date']}'),
                        label: Text(text('ExperimentDidnt')),
                        selected: _answers[day['date']] == false,
                        onSelected: (_) => _answer(day['date'] as String, false),
                      ),
                    ],
                  ),
              ],
            ),
      ],
    ]);
  }
}
