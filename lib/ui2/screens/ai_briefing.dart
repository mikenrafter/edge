import 'coach_text.dart';
// THE DATA BOUNDARY — the daily briefing, and exactly what left the device to
// produce it.
//
// `Briefing.inputs` is the compact metric snapshot the prompt was built from,
// stored beside every briefing since the engine was written. Nothing ever read
// it. That map IS the payload — `buildBriefingUserPrompt` writes one `key: value`
// line per entry and adds nothing — so this screen can state, exactly and
// without hedging, what a third party received.
//
// For an app whose whole argument is that the data stays on the phone, this is
// not a nicety. It is the thing that makes choosing a cloud key a decision
// rather than a leap, and it is why the local presets come first in setup.

import '../../l10n/display_text.dart';
import 'package:flutter/material.dart';

import '../../data/read_paused.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../ai/briefing_engine.dart';
import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart' show CoachException;
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'coach.dart' show CoachSetup, kCoachAccent;
import 'home_screen.dart' show go, pad, repoOf;

class AiBriefingScreen extends StatefulWidget {
  final BriefingPeriod period;
  const AiBriefingScreen({super.key, required this.period});

  @override
  State<AiBriefingScreen> createState() => _AiBriefingScreenState();
}

class _AiBriefingScreenState extends State<AiBriefingScreen> {
  Briefing? _b;
  bool _busy = false;
  String? _error;
  bool _paused = false; // an import has the database: try again after it

  @override
  void initState() {
    super.initState();
    _b = BriefingStore.read(widget.period);
  }

  Future<void> _generate() async {
    final repo = repoOf(context);
    if (repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _paused = false;
    });
    try {
      final b = await BriefingEngine(
        config: context.read<CoachConfig>(),
        repo: repo,
      ).generate(widget.period);
      if (mounted) setState(() => _b = b);
    } on ReadPaused {
      if (mounted) setState(() => _paused = true);
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(
          () => _error = e is CoachException
              ? e.message
              : (l?.aiBriefingFailedGeneric('$e') ?? 'Could not write the briefing: $e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cfg = c.watch<CoachConfig>();
    final b = _b;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            NavBar(
                uiText(c, widget.period.title),
                sub: b == null
                    ? ''
                    : (l?.aiBriefingForDay(b.day) ?? 'FOR ${b.day}'),
              ),
            Expanded(
              child: ListView(
                padding: pad,
                children: [
                  const SizedBox(height: S.x2),
                  if (!cfg.configured)
                    StatusCard(
                      l?.aiBriefingNoModelTitle ?? 'No model is set up',
                      l?.aiBriefingNoModelBody ??
                          'Pick a model to generate briefings.',
                      fix: l?.aiBriefingChooseModel ?? 'Choose a model',
                      icon: LucideIcons.sparkles,
                      onFix: () => go(c, const CoachSetup()),
                    )
                  else if (b == null)
                    StatusCard(
                      l?.aiBriefingNothingTitle ?? 'Nothing written for today',
                      l?.aiBriefingNothingBody ??
                          'Briefings appear here.',
                      fix: _busy
                          ? (l?.aiBriefingWriting ?? 'Writing…')
                          : (l?.aiBriefingWriteNow ?? 'Write one now'),
                      icon: LucideIcons.sun,
                      onFix: _busy ? null : _generate,
                    )
                  else ...[
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.oneLiner == 'Nothing stood out tonight.'
                                ? uiText(c, b.oneLiner)
                                : b.oneLiner,
                            style: F.body.copyWith(color: p.ink, height: 1.5),
                          ),
                          if (b.olderVersions.isNotEmpty) ...[
                            const SizedBox(height: S.x3),
                            // Fixed text, not parsed from the model's prose: the
                            // note is true whatever the model chose to quote.
                            Text(
                              l?.briefingOlderFootnote(
                                      b.olderVersions.map((v) => 'v$v').join(', ')) ??
                                  'Some figures in this note come from an older '
                                      'calculation (${b.olderVersions.map((v) => 'v$v').join(', ')}).',
                              key: const ValueKey('briefing-older-footnote'),
                              style: F.cap.copyWith(color: p.ink3, height: 1.5),
                            ),
                          ],
                          if (b.breakdownMd.isNotEmpty) ...[
                            const SizedBox(height: S.x3),
                            Text(
                              b.breakdownMd,
                              style: F.cap.copyWith(color: p.ink2, height: 1.6),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: S.x3),
                    BigButton(
                      _busy
                          ? (l?.aiBriefingWriting ?? 'Writing…')
                          : (l?.aiBriefingWriteAgain ?? 'Write it again'),
                      icon: LucideIcons.refreshCw,
                      color: kCoachAccent,
                      soft: true,
                      onTap: _busy ? null : _generate,
                    ),
                  ],
                  if (_paused) ...[
                    const SizedBox(height: S.x3),
                    const PausedToday(),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      l?.aiBriefingFailedTitle ?? 'That did not go through',
                      coachPresentationText(l, _error!),
                      icon: LucideIcons.triangleAlert,
                    ),
                  ],
                  if (b != null)
                    SentPayload(
                      inputs: b.inputs,
                      config: cfg,
                      asked: b.calledModel,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What was sent, in full. Not a summary of it — the same map, every key.
///
/// A screen that showed "12 metrics" would be worse than nothing: it asks to be
/// trusted about the exact question it exists to answer.
class SentPayload extends StatelessWidget {
  final Map<String, dynamic> inputs;
  final CoachConfig config;

  /// Whether a model was called at all — [Briefing.calledModel]. False for a
  /// nightly sweep that found nothing: there was no request, so the banner may
  /// not describe one.
  final bool asked;

  const SentPayload({
    super.key,
    required this.inputs,
    required this.config,
    this.asked = true,
  });

  /// True when the endpoint is on this machine, in which case nothing left it.
  static bool isLocal(String base) {
    final h = Uri.tryParse(base)?.host.toLowerCase() ?? '';
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  static String _label(String key) {
    final s = key.replaceAll('_', ' ');
    return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// Verbatim, because this is a preview of a payload and not a metric card.
  /// [buildBriefingUserPrompt] writes `$v` for every entry, so a null reaches
  /// the model as the word `null` and this has to say the same — an em dash
  /// here would read as "withheld" for a value that was in fact sent, empty.
  /// (`_put` drops absent metrics before they get this far, so this is the
  /// belt and not the trousers.)
  static String _value(dynamic v) => v is List ? v.join(', ') : '$v';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final host = Uri.tryParse(config.apiBase)?.host ?? config.apiBase;
    final local = isLocal(config.apiBase);
    final keys = inputs.keys.toList()..sort();
    // An empty payload is not "we sent an empty payload". The nightly sweep
    // calls no model at all on a day with no finding, so the banner must not go
    // on describing a request that never happened.
    final none = !asked;
    return Section(
      none || !local
          ? (l?.aiBriefingSentSection ?? 'What was sent')
          : (l?.aiBriefingReadSection ?? 'What was read'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Surface(
            elevation: 0,
            color: p.wash(none || local ? C.green : C.orange),
            child: Row(
              children: [
                Icon(
                  none || local
                      ? LucideIcons.house
                      : LucideIcons.cloudUpload,
                  size: 17,
                  color: p.on(none || local ? C.green : C.orange),
                ),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Text(
                    none
                        ? (l?.aiBriefingNoneBody ??
                            'Nothing was sent.')
                        : local
                            ? (l?.aiBriefingLocalBody(host) ??
                                'These numbers went to $host on this device.')
                            : (l?.aiBriefingCloudBody(host, config.model) ??
                                'Only these numbers were sent to $host (${config.model}). No name or raw recordings.'),
                    style: F.cap.copyWith(color: p.ink, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: S.x3),
          if (none)
            StatusCard(
              l?.aiBriefingNoneCardBody ??
                  'No model was called because nothing stood out.',
              '',
              icon: LucideIcons.circleSlash,
            )
          else if (keys.isEmpty)
            StatusCard(
              l?.aiBriefingEmptyCardBody ?? 'No data to send.',
              '',
              icon: LucideIcons.circleSlash,
            )
          else
            Surface(
              pad: const EdgeInsets.symmetric(
                horizontal: S.x4,
                vertical: S.x2,
              ),
              child: Column(
                children: [
                  for (final k in keys)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: S.x2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              uiText(c, _label(k)),
                              style: F.cap.copyWith(color: p.ink3),
                            ),
                          ),
                          const SizedBox(width: S.x3),
                          Flexible(
                            child: Text(
                              _value(inputs[k]),
                              textAlign: TextAlign.right,
                              style: F.cap.copyWith(color: p.ink),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
