// WHOOP MG ECG — the Heart Screener entry (history + Take ECG), the capture
// screen and the reading detail.
//
// The entry is gated on the paired band being a REMEMBERED WHOOP MG; inside
// it, saved readings read fine while the band is away and "Take ECG" needs
// the MG connected and READY. Everything shown as a result is the band's own
// category — labelled so — never a phone-side classification.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../coach/coach_config.dart';
import '../../compute/derivation_engine.dart'
    show kAlgoVersion, kAnalyticsPin, kProtocolPin;
import '../../data/db.dart';
import '../../ecg/ecg_controller.dart';
import '../../ecg/ecg_export.dart';
import '../../ecg/ecg_models.dart';
import '../../ecg/ecg_outcome.dart';
import '../../ecg/ecg_result.dart';
import '../../ecg/ecg_seconds.dart';
import '../../ecg/ecg_waveform_buffer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../../util/log_file.dart'
    show LogResultSaver, LogSaveFailed, logFileName, saveLogFileResult;
import '../profile/profile.dart' show SwitchRow;
import '../ui2.dart';
import 'coach.dart';
import 'ecg_screener.dart';
import 'home_screen.dart' show go, pad;

String ecgCategoryLabel(AppLocalizations? l, EcgCategory c) => switch (c) {
  EcgCategory.sinusRhythm => l?.ecgCategorySinus ?? 'Regular rhythm reported',
  EcgCategory.lowHeartRate => l?.ecgCategoryLowHr ?? 'Low heart rate',
  EcgCategory.possibleAfib => l?.ecgCategoryPossibleAfib ?? 'Irregular rhythm flagged',
  EcgCategory.afibHighHeartRate =>
    l?.ecgCategoryAfibHighHr ?? 'Irregular rhythm flagged, high heart rate',
  EcgCategory.highHeartRate => l?.ecgCategoryHighHr ?? 'High heart rate',
  EcgCategory.highHeartRateNoAfib =>
    l?.ecgCategoryHighHrNoAfib ??
        'High heart rate, no irregular rhythm flagged',
  EcgCategory.inconclusive => l?.ecgCategoryInconclusive ?? 'Inconclusive',
  EcgCategory.unreadable => l?.ecgCategoryUnreadable ?? 'Unreadable',
};

/// What an outcome is called, everywhere (capture, history row, detail): a
/// rhythm label only for a band result; otherwise what the recording supports.
String ecgOutcomeLabel(AppLocalizations? l, EcgOutcome o) => switch (o.kind) {
  EcgOutcomeKind.bandResult => ecgCategoryLabel(l, o.bandResult!),
  EcgOutcomeKind.inconclusive => l?.ecgCategoryInconclusive ?? 'Inconclusive',
  EcgOutcomeKind.notReadable => l?.ecgOutcomeNotReadable ?? 'Not readable',
  EcgOutcomeKind.partial => l?.ecgStoppedEarly ?? 'Stopped early',
};

/// What a saved reading is called in a list: its [ecgOutcome], never the
/// stored category (a set band reason bit or a mismatched rate is re-judged).
String ecgReadingLabel(AppLocalizations? l, EcgReading r) =>
    ecgOutcomeLabel(l, ecgOutcome(r));

/// One reason in words.
String ecgReasonText(AppLocalizations? l, EcgReason r) {
  final n = r.arg ?? 0;
  return switch (r.id) {
    EcgReasonId.lowAmplitude => l?.ecgReasonLowAmplitude ?? 'Low amplitude',
    EcgReasonId.significantNoise => l?.ecgReasonNoise ?? 'Significant noise',
    EcgReasonId.unstableSignal => l?.ecgReasonUnstable ?? 'Unstable signal',
    EcgReasonId.notEnoughData =>
      l?.ecgReasonNotEnoughData ?? 'Not enough data',
    EcgReasonId.unknownBandReasonBit =>
      l?.ecgReasonUnknownBit(n) ?? 'Unknown band reason bit $n',
    EcgReasonId.unknownResultCode =>
      l?.ecgReasonUnknownCode(n) ??
          'The band\'s result code $n is not one this app knows',
    EcgReasonId.bandUnreadableResult =>
      l?.ecgReasonBandUnreadable(n) ??
          'The band\'s result code $n means it could not read the recording',
    EcgReasonId.noHeartRate =>
      l?.ecgReasonNoHeartRate ?? 'No heart rate was reported',
    EcgReasonId.heartRateOutOfRange =>
      l?.ecgReasonHrOutOfRange(n) ??
          'The average heart rate ($n bpm) is outside the range this result '
              'can be read at',
    _ => r.id,
  };
}

/// Why a partial reading stopped, in words.
String ecgStopReasonLabel(String? reason) => switch (reason) {
  'paused' => 'The app went to the background.',
  'timeout' => 'No result within two minutes.',
  'disconnected' => 'The band disconnected.',
  _ => '',
};

List<String> ecgReasonLabels(AppLocalizations? l, int mask) => [
  for (final r in ecgMaskReasons(mask)) ecgReasonText(l, r),
];

String _wristLabel(AppLocalizations? l, EcgWrist w) => w == EcgWrist.left
    ? (l?.ecgWristLeft ?? 'Left wrist')
    : (l?.ecgWristRight ?? 'Right wrist');

String _fmtWhen(int epochS) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochS * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// ═══════════════════ export (home and detail) ═══════════════════

/// The production export environment: the installed app's version and the wall
/// clock. Tests hand in their own.
EcgExportEnv _defaultExportEnv() => EcgExportEnv(
  appVersion: () async {
    final i = await PackageInfo.fromPlatform();
    return '${i.version}+${i.buildNumber}';
  },
  now: DateTime.now,
);

/// Runs one ECG export end to end - build the log with the one formatter, name
/// it from the clock, hand it to the saver - and returns null when it was
/// saved, or the reason it was not. [readingId] null = every reading (the
/// bulk log), else that reading's attempt group. Never throws: a failure is a
/// reason a person can read, shown as "Couldn't save the ECG log: REASON"
/// (AGENTS 6: results, not booleans), and nothing reads as saved.
Future<String?> _runEcgExport({
  required EcgExportEnv? env,
  required EcgReadingSource? source,
  required LogResultSaver? save,
  String? readingId,
}) async {
  try {
    final e = env ?? _defaultExportEnv();
    final src = source ?? const LocalDbEcgSource();
    final at = e.now();
    final header = EcgExportHeader(
      appVersion: await e.appVersion(),
      analyticsPin: kAnalyticsPin,
      protocolPin: kProtocolPin,
      algoVersion: kAlgoVersion,
      outcomeTableVersion: kEcgOutcomeTableVersion,
      exportedAt: at,
    );
    final text = readingId == null
        ? await buildEcgLogAll(header: header, source: src)
        : await buildEcgLogFor(header: header, source: src, readingId: readingId);
    final saver = save ?? ((name, text) => saveLogFileResult(name, text));
    final res = await saver(logFileName('ecg', at), text);
    return res is LogSaveFailed ? res.reason : null;
  } catch (err) {
    return '$err';
  }
}

/// A button-like text row for the export actions.
class _ExportRow extends StatelessWidget {
  const _ExportRow({
    required this.buttonKey,
    required this.label,
    required this.busy,
    required this.onTap,
    required this.failure,
  });
  final Key buttonKey;
  final String label;
  final bool busy;
  final VoidCallback onTap;

  /// The failure reason of the last attempt, or null.
  final String? failure;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pressable(
          key: buttonKey,
          semanticLabel: label,
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x2),
            child: Row(
              children: [
                Icon(LucideIcons.share, size: 16, color: p.on(C.blue)),
                const SizedBox(width: S.x2),
                Expanded(
                  child: Text(label, style: F.body.copyWith(color: p.on(C.blue))),
                ),
              ],
            ),
          ),
        ),
        if (failure != null)
          Semantics(
            liveRegion: true,
            child: Text(
              l?.ecgExportFailed(failure!) ??
                  'Couldn\'t save the ECG log: $failure',
              style: F.cap.copyWith(color: C.red),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════ entry card (Health overview) ═══════════════════

/// The Health-overview door. Only built when [pairedIsMaverickOf] is true.
class EcgEntryCard extends StatelessWidget {
  const EcgEntryCard({super.key});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return ActionCard(
      l?.ecgHeartScreener ?? 'Heart Screener',
      l?.ecgEntryMeta ?? 'WHOOP MG · band-reported',
      l?.ecgOpen ?? 'Open',
      LucideIcons.activity,
      C.domHealth,
      onTap: () => go(c, const EcgHomeScreen()),
    );
  }
}

// ═══════════════════ home: history + Take ECG ═══════════════════

class EcgHomeScreen extends StatefulWidget {
  /// Design 04 R7: the seams "Export ECG logs" runs through (tests hand in
  /// fakes; defaults are the real LocalDb source, the platform share sheet and
  /// the wall clock).
  final LogResultSaver? saveLog;
  final EcgReadingSource? exportSource;
  final EcgExportEnv? exportEnv;
  const EcgHomeScreen({
    super.key,
    this.saveLog,
    this.exportSource,
    this.exportEnv,
  });

  @override
  State<EcgHomeScreen> createState() => _EcgHomeScreenState();
}

class _EcgHomeScreenState extends State<EcgHomeScreen> {
  List<EcgReading> _readings = const [];
  bool _loaded = false;
  bool _exporting = false;
  String? _exportFailure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await LocalDb.listEcgReadings();
      final list = [for (final r in rows) ?EcgReading.fromRow(r)];
      if (!mounted) return;
      setState(() {
        _readings = list;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _take(BuildContext c, AppState app) async {
    final serial = app.ecg.transport.serial;
    final remembered = serial == null
        ? null
        : await app.ecg.guard.wrist(serial);
    if (!c.mounted) return;
    final wrist = await showModalBottomSheet<EcgWrist>(
      context: c,
      sheetAnimationStyle: sheetMotion(c),
      builder: (_) => EcgWristSheet(current: remembered),
    );
    if (wrist == null || !c.mounted) return;
    await Navigator.of(c).push(
      themedRoute(
        (_) => EcgCaptureScreen(wrist: wrist),
        name: 'EcgCaptureScreen',
      ),
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    final id = app.ecg.state.readingId;
    if (app.ecg.state.phase == EcgCapturePhase.completed && id != null) {
      unawaited(_openDetail(context, id));
    }
  }

  Future<void> _openDetail(BuildContext c, String id) async {
    final data = await EcgDetailData.load(id);
    if (!c.mounted || data == null) return;
    await Navigator.of(c).push(
      themedRoute((_) => EcgDetailScreen(data: data), name: 'EcgDetailScreen'),
    );
    if (mounted) await _load();
  }

  /// "Export ECG logs": every reading, superseded attempts included, as ONE
  /// log file through the share sheet. The busy flag is cleared in `finally`
  /// (AGENTS 4.3) and the failure, if any, stays on screen.
  Future<void> _exportAll() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportFailure = null;
    });
    String? failure;
    try {
      failure = await _runEcgExport(
        env: widget.exportEnv,
        source: widget.exportSource,
        save: widget.saveLog,
      );
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportFailure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final app = c.watch<AppState>();
    final take = c.caps.of(Feature.ecgTake);
    final canTake = take.isAvailable;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        title: Text(l?.ecgHeartScreener ?? 'Heart Screener'),
      ),
      body: ListView(
        padding: pad,
        children: [
          ActionCard(
            l?.ecgTakeEcg ?? 'Take ECG',
            canTake
                ? (l?.ecgEntryMeta ?? 'WHOOP MG · band-reported')
                : (l?.ecgNeedsMg ?? take.reason ?? ''),
            l?.ecgTakeEcg ?? 'Take ECG',
            LucideIcons.heartPulse,
            C.domHealth,
            onTap: canTake ? () => _take(c, app) : null,
          ),
          const SizedBox(height: S.x2),
          SwitchRow(
            'Keep waveform',
            app.ecgKeepWaveform,
            (v) => unawaited(app.setEcgKeepWaveform(v)),
            sub:
                'Save the recorded signal with each reading. Off: only the '
                'result, heart rate and signal quality are kept.',
          ),
          Pressable(
            key: const ValueKey('ecg-screener-link'),
            semanticLabel: 'What the results mean',
            onTap: () => go(c, const EcgScreenerScreen()),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'What the results mean',
                      style: F.body.copyWith(color: p.on(C.blue)),
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 16, color: p.on(C.blue)),
                ],
              ),
            ),
          ),
          _ExportRow(
            buttonKey: const ValueKey('ecg-export-all'),
            label: l?.ecgExportAll ?? 'Export ECG logs',
            busy: _exporting,
            onTap: _exportAll,
            failure: _exportFailure,
          ),
          const SizedBox(height: S.x4),
          if (_loaded && _readings.isEmpty)
            StatusCard(
              l?.ecgHistoryEmpty ?? 'No readings yet.',
              l?.ecgHistoryEmptyWhy ??
                  'Your saved readings appear here and open without the band connected.',
              icon: LucideIcons.activity,
            ),
          if (_readings.isNotEmpty)
            Section(
              l?.ecgTitle ?? 'ECG',
              Surface(
                pad: const EdgeInsets.symmetric(vertical: S.x1),
                child: Column(
                  children: [
                    for (var i = 0; i < _readings.length; i++) ...[
                      if (i > 0) Divider(color: p.line, height: 1),
                      EcgReadingRow(
                        reading: _readings[i],
                        onTap: () => _openDetail(c, _readings[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One saved reading in the history list.
class EcgReadingRow extends StatelessWidget {
  final EcgReading reading;
  final VoidCallback? onTap;
  const EcgReadingRow({super.key, required this.reading, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final outcome = ecgOutcome(reading);
    final cat = ecgOutcomeLabel(l, outcome);
    // A rate next to "Not readable" would be a number the recording does not
    // support; it stays in Details.
    final hr = outcome.kind == EcgOutcomeKind.bandResult && (reading.avgHr ?? 0) > 0
        ? reading.avgHr
        : null;
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '$cat, ${hr == null ? '' : '$hr bpm, '}${_fmtWhen(reading.startTs)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cat, style: F.body.copyWith(color: p.ink)),
                  const SizedBox(height: S.x1),
                  Text(
                    '${_fmtWhen(reading.startTs)} · ${_wristLabel(l, reading.wrist)}',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            if (hr != null) Text('$hr', style: F.n24.copyWith(color: p.ink)),
            if (hr != null) const SizedBox(width: S.x1),
            if (hr != null) Text('bpm', style: F.cap.copyWith(color: p.ink3)),
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
          ],
        ),
      ),
    );
  }
}

/// "Which wrist is the band on?" — pops the choice.
class EcgWristSheet extends StatelessWidget {
  final EcgWrist? current;
  const EcgWristSheet({super.key, this.current});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    Widget option(EcgWrist w, IconData icon) => Pressable(
      semanticLabel: _wristLabel(l, w),
      onTap: () => Navigator.of(c).pop(w),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x5, vertical: S.x4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: p.ink2),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                _wristLabel(l, w),
                style: F.body.copyWith(color: p.ink),
              ),
            ),
            if (current == w)
              Icon(LucideIcons.check, size: 18, color: C.domHealth),
          ],
        ),
      ),
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x5, S.x5, S.x5, S.x2),
            child: Text(
              l?.ecgWristPrompt ?? 'Which wrist is the band on?',
              style: F.head.copyWith(color: p.ink),
            ),
          ),
          option(EcgWrist.left, LucideIcons.arrowLeft),
          option(EcgWrist.right, LucideIcons.arrowRight),
          const SizedBox(height: S.x3),
        ],
      ),
    );
  }
}

// ═══════════════════ capture ═══════════════════

class EcgCaptureScreen extends StatefulWidget {
  final EcgWrist wrist;

  /// The controller to drive; defaults to the app's. Tests hand in their own.
  final EcgController? controller;
  const EcgCaptureScreen({super.key, required this.wrist, this.controller});

  @override
  State<EcgCaptureScreen> createState() => _EcgCaptureScreenState();
}

class _EcgCaptureScreenState extends State<EcgCaptureScreen>
    with SingleTickerProviderStateMixin {
  EcgController? _c;
  Ticker? _ticker;
  Timer? _slowTick;
  double _phase = 0;
  Duration _lastPreview = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.controller ?? context.read<AppState>().ecg;
      c.addListener(_onController);
      setState(() => _c = c);
      _startClock();
      unawaited(c.begin(widget.wrist));
    });
  }

  void _startClock() {
    if (Motion.enabled(context)) {
      _ticker = createTicker(_onTick)..start();
    } else {
      // Reduced motion: no animation, but the live preview still needs a
      // clock to repaint on — one coalesced repaint per second.
      _slowTick = Timer.periodic(Motion.tick, (_) {
        _c?.preview.tick();
      });
    }
  }

  void _onTick(Duration elapsed) {
    final pulseMs = Motion.ecgPulse.inMilliseconds;
    final t = (elapsed.inMilliseconds % pulseMs) / pulseMs;
    if (elapsed - _lastPreview >= Motion.ecgPreviewTick) {
      _lastPreview = elapsed;
      _c?.preview.tick();
    }
    if (mounted) setState(() => _phase = t);
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _slowTick?.cancel();
    _c?.removeListener(_onController);
    // Leaving the screen by any route stops the reading (fire-and-forget:
    // the controller's own cleanup path is idempotent).
    final c = _c;
    if (c != null && c.isCapturing) unawaited(c.cancel());
    super.dispose();
  }

  Future<void> _close(BuildContext c) async {
    final ctl = _c;
    if (ctl != null && ctl.isCapturing) await ctl.cancel();
    if (c.mounted) Navigator.of(c).pop();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final ctl = _c;
    final s = ctl?.state ?? const EcgCaptureState();
    final busy = ctl?.isCapturing ?? false;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !busy) return;
        await _close(c);
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Pressable(
                    semanticLabel: l?.ecgClose ?? 'Close ECG',
                    onTap: () => _close(c),
                    child: Icon(LucideIcons.x, size: 22, color: p.ink2),
                  ),
                ),
                Expanded(
                  child: ctl == null
                      ? const SizedBox.shrink()
                      : EcgCaptureBody(
                          state: s,
                          wrist: widget.wrist,
                          phase: _phase,
                          live: ctl.live,
                          scheduler: ctl.preview,
                          onRetry: ctl.retry,
                          onTakeAnother: () => ctl.begin(widget.wrist),
                          onDone: () => _close(c),
                          onView: () async {
                            final id = s.readingId;
                            if (id == null) return;
                            final data = await EcgDetailData.load(id);
                            if (!c.mounted || data == null) return;
                            await Navigator.of(c).pushReplacement(
                              themedRoute(
                                (_) => EcgDetailScreen(data: data),
                                name: 'EcgDetailScreen',
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The capture screen's content for one [state] — pure, data in, callbacks
/// out, so every phase can be pumped in a test without a band.
class EcgCaptureBody extends StatelessWidget {
  final EcgCaptureState state;
  final EcgWrist wrist;
  final double phase;
  final EcgWaveformBuffer live;
  final EcgPreviewScheduler scheduler;
  final VoidCallback onRetry;
  final VoidCallback onTakeAnother;
  final VoidCallback onDone;
  final VoidCallback onView;

  const EcgCaptureBody({
    super.key,
    required this.state,
    required this.wrist,
    required this.phase,
    required this.live,
    required this.scheduler,
    required this.onRetry,
    required this.onTakeAnother,
    required this.onDone,
    required this.onView,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final s = state;
    Widget title(String t) => Text(t, style: F.t2.copyWith(color: p.ink));
    Widget body(String t) =>
        Text(t, style: F.body.copyWith(color: p.ink2, height: 1.4));
    Widget button(String label, VoidCallback? onTap, {bool primary = true}) =>
        Pressable(
          semanticLabel: label,
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: S.x3),
            decoration: BoxDecoration(
              color: primary ? p.fill(C.domHealth) : p.card2,
              borderRadius: R.rMd,
            ),
            child: Text(
              label,
              style: F.body.copyWith(
                color: primary ? p.inkOnFill : p.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );

    final capturing = switch (s.phase) {
      EcgCapturePhase.recovering ||
      EcgCapturePhase.preparing ||
      EcgCapturePhase.starting ||
      EcgCapturePhase.waiting ||
      EcgCapturePhase.active ||
      EcgCapturePhase.contactLost ||
      EcgCapturePhase.restarting => true,
      _ => false,
    };
    final armed = switch (s.phase) {
      EcgCapturePhase.starting ||
      EcgCapturePhase.waiting ||
      EcgCapturePhase.active ||
      EcgCapturePhase.contactLost ||
      EcgCapturePhase.restarting => true,
      _ => false,
    };
    final measuring =
        s.phase == EcgCapturePhase.active ||
        s.phase == EcgCapturePhase.contactLost ||
        s.phase == EcgCapturePhase.restarting;

    if (capturing) {
      final status = switch (s.phase) {
        EcgCapturePhase.recovering =>
          l?.ecgRecovering ?? 'Stopping a previous reading first…',
        EcgCapturePhase.preparing => l?.ecgPreparing ?? 'Preparing the band…',
        EcgCapturePhase.starting ||
        EcgCapturePhase.waiting => l?.ecgWaiting ?? 'Waiting for contact',
        EcgCapturePhase.active => l?.ecgMeasuring ?? 'Measuring',
        EcgCapturePhase.contactLost =>
          l?.ecgContactLost ?? 'Adjust your fingers and keep still',
        EcgCapturePhase.restarting => l?.ecgRestarting ?? 'Restarting…',
        _ => '',
      };
      return ListView(
        padding: const EdgeInsets.only(bottom: S.x8),
        children: [
          const SizedBox(height: S.x2),
          EcgTouchIllustration(
            wrist: wrist,
            t: phase,
            contact: measuring,
            semanticLabel:
                l?.ecgIllustration ??
                'Illustration: the band on your wrist, and the thumb and index '
                    'finger of your other hand touching its two metal sides.',
          ),
          const SizedBox(height: S.x4),
          body(
            l?.ecgInstruction ??
                'Rest your arm. Touch both metal sides with your opposite thumb '
                    'and index finger. Keep still.',
          ),
          const SizedBox(height: S.x4),
          Text(
            status,
            key: const ValueKey('ecg-status'),
            style: F.head.copyWith(
              color: s.phase == EcgCapturePhase.contactLost ? C.orange : p.ink,
            ),
          ),
          if (measuring) ...[
            const SizedBox(height: S.x2),
            Semantics(
              label: l?.ecgProgress(s.progress) ?? '${s.progress}% complete',
              child: ClipRRect(
                borderRadius: R.rSm,
                child: LinearProgressIndicator(
                  value: s.progress / 100,
                  minHeight: 8,
                  backgroundColor: p.track,
                  color: C.domHealth,
                ),
              ),
            ),
            if (s.quality > 0) ...[
              const SizedBox(height: S.x2),
              EcgMetricsList(
                metrics: [
                  EcgMetric(
                    key: 'quality',
                    name: 'Signal quality',
                    value: s.quality.toDouble(),
                    unit: '',
                  ),
                ],
              ),
            ],
            const SizedBox(height: S.x2),
            Row(
              children: [
                Text(
                  l?.ecgProgress(s.progress) ?? '${s.progress}% complete',
                  style: F.cap.copyWith(color: p.ink3),
                ),
                const Spacer(),
                if (s.liveHr != null) ...[
                  Text('${s.liveHr}', style: F.n24.copyWith(color: p.ink)),
                  const SizedBox(width: S.x1),
                  Text('bpm', style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
            ),
          ],
          if (armed) ...[
            const SizedBox(height: S.x4),
            EcgLivePreview(
              buffer: live,
              scheduler: scheduler,
              label: l?.ecgLivePreview ?? 'Live signal preview',
              unit: 'µV',
            ),
          ],
        ],
      );
    }

    switch (s.phase) {
      case EcgCapturePhase.idle:
        return const SizedBox.shrink();
      case EcgCapturePhase.incompatible:
        return StatusCard(
          l?.ecgIncompatible ?? 'This band is not a WHOOP MG.',
          l?.ecgNeedsMg ?? 'Take ECG needs a connected WHOOP MG.',
          icon: LucideIcons.circleOff,
        );
      case EcgCapturePhase.disconnected:
        return StatusCard(
          l?.ecgDisconnected ?? 'Connect your WHOOP MG first.',
          l?.ecgNeedsMg ?? 'Take ECG needs a connected WHOOP MG.',
          icon: LucideIcons.bluetoothOff,
        );
      case EcgCapturePhase.busy:
        return StatusCard(
          l?.ecgBusy ?? 'Finish the other live session first.',
          s.reason ?? '',
          icon: LucideIcons.hourglass,
        );
      case EcgCapturePhase.saving:
      case EcgCapturePhase.cleaningUp:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: S.x4),
              body(
                s.phase == EcgCapturePhase.saving
                    ? (l?.ecgSaving ?? 'Saving…')
                    : (l?.ecgCleaningUp ?? 'Stopping the band…'),
              ),
            ],
          ),
        );
      case EcgCapturePhase.completed:
        final o = s.outcome;
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(l?.ecgCompleted ?? 'Reading saved'),
            const SizedBox(height: S.x2),
            if (o != null) ...[
              _EcgOutcomeBlock(outcome: o),
              const SizedBox(height: S.x2),
            ],
            body(
              l?.ecgNotDiagnosis ??
                  'The category comes from the band. This is a screen, not a medical test.',
            ),
            // A rate beside "Not readable" is a number the recording does not
            // support; it stays in the reading's Details.
            if (s.metrics.isNotEmpty &&
                o?.kind != EcgOutcomeKind.notReadable) ...[
              const SizedBox(height: S.x4),
              EcgMetricsList(metrics: s.metrics),
            ],
            if (s.cleanupIncomplete) ...[
              const SizedBox(height: S.x3),
              body(
                l?.ecgCleanupIncomplete ??
                    'The band may still be recording. The app will stop it on '
                    'the next connection.',
              ),
            ],
            const SizedBox(height: S.x6),
            button(l?.ecgViewReading ?? 'View reading', onView),
            if (o != null && o.kind != EcgOutcomeKind.bandResult) ...[
              const SizedBox(height: S.x3),
              button(
                l?.ecgTakeAnother ?? 'Take another',
                onTakeAnother,
                primary: false,
              ),
            ],
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.unreadable:
        final o = s.outcome;
        final reasons = o != null
            ? [for (final r in o.reasons) ecgReasonText(l, r)]
            : ecgReasonLabels(l, s.unreadableMask);
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(
              o != null
                  ? (l?.ecgOutcomeNotReadable ?? 'Not readable')
                  : (l?.ecgUnreadableTitle ?? 'The band could not read this'),
            ),
            const SizedBox(height: S.x2),
            body(l?.ecgOutcomeNoRhythm ?? 'This recording does not support a rhythm reading.'),
            for (final r in reasons) ...[
              const SizedBox(height: S.x1),
              Text('· $r', style: F.body.copyWith(color: p.ink)),
            ],
            const SizedBox(height: S.x6),
            if (s.readingId != null) ...[
              button(l?.ecgViewReading ?? 'View reading', onView),
              const SizedBox(height: S.x3),
            ],
            button(
              l?.ecgTakeAnother ?? 'Take another',
              onTakeAnother,
              primary: s.readingId == null,
            ),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.inconclusiveRetry:
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(l?.ecgInconclusiveTitle ?? 'Inconclusive'),
            const SizedBox(height: S.x2),
            body(
              l?.ecgInconclusiveRetryHint ??
                  'The band could not decide. You can try once more.',
            ),
            const SizedBox(height: S.x6),
            button(l?.ecgTryOnceMore ?? 'Try once more', onRetry),
            if (s.readingId != null) ...[
              const SizedBox(height: S.x3),
              button(
                l?.ecgViewReading ?? 'View reading',
                onView,
                primary: false,
              ),
            ],
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.cancelled:
      case EcgCapturePhase.failed:
        final why = switch (s.reason) {
          'disconnected' =>
            l?.ecgFailedDisconnected ?? 'The band disconnected.',
          'timeout' => l?.ecgFailedTimeout ?? 'No result within two minutes.',
          'cancelled' || null => '',
          'paused' => ecgStopReasonLabel('paused'),
          final r =>
            l?.ecgFailedGeneric(r) ??
                'The band did not accept the reading ($r).',
        };
        final partial = s.result == EcgReadingStatus.partial;
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(
              partial
                  ? 'Stopped early'
                  : s.phase == EcgCapturePhase.cancelled
                  ? (l?.ecgCancelledTitle ?? 'Reading cancelled')
                  : (l?.ecgFailedTitle ?? 'Reading failed'),
            ),
            if (partial) ...[
              const SizedBox(height: S.x2),
              body(
                'What was recorded is saved as a partial reading. It was not '
                'screened, so no rhythm result is given.',
              ),
            ],
            if (why.isNotEmpty) ...[const SizedBox(height: S.x2), body(why)],
            if (partial && s.metrics.isNotEmpty) ...[
              const SizedBox(height: S.x4),
              EcgMetricsList(metrics: s.metrics),
            ],
            if (s.cleanupIncomplete) ...[
              const SizedBox(height: S.x3),
              body(
                l?.ecgCleanupIncomplete ??
                    'The band may still be recording. The app will stop it on '
                    'the next connection.',
              ),
            ],
            const SizedBox(height: S.x6),
            if (partial && s.readingId != null) ...[
              button(l?.ecgViewReading ?? 'View reading', onView),
              const SizedBox(height: S.x3),
            ],
            button(l?.ecgTakeAnother ?? 'Take another', onTakeAnother),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// The outcome as a headline plus what supports it: the label (a rhythm label
/// only for a band result), the reasons a rhythm may not be read, and the
/// caveat that the app has not checked the recording's quality. Used by the
/// capture result and the detail headline, so they cannot say different things.
class _EcgOutcomeBlock extends StatelessWidget {
  final EcgOutcome outcome;

  /// Draw the label as the large headline (the detail screen shows its own).
  final bool showLabel;
  const _EcgOutcomeBlock({required this.outcome, this.showLabel = true});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final o = outcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel)
          Text(ecgOutcomeLabel(l, o), style: F.head.copyWith(color: p.ink)),
        if (o.kind == EcgOutcomeKind.notReadable ||
            o.kind == EcgOutcomeKind.inconclusive) ...[
          const SizedBox(height: S.x1),
          Text(
            l?.ecgOutcomeNoRhythm ??
                'This recording does not support a rhythm reading.',
            style: F.body.copyWith(color: p.ink2, height: 1.4),
          ),
        ],
        for (final r in o.reasons) ...[
          const SizedBox(height: S.x1),
          Text('· ${ecgReasonText(l, r)}', style: F.body.copyWith(color: p.ink)),
        ],
        if (o.caveats.contains(EcgCaveat.bandReportedQualityUnchecked)) ...[
          const SizedBox(height: S.x1),
          Text(
            l?.ecgCaveatQualityUnchecked ??
                'Band-reported. The app has not checked this recording\'s '
                    'quality yet.',
            style: F.cap.copyWith(color: p.ink3, height: 1.4),
          ),
        ],
      ],
    );
  }
}

// ═══════════════════ detail ═══════════════════

class EcgDetailData {
  final EcgReading reading;
  final List<EcgAcceptedPacket> packets;

  /// Design 04 R2: every attempt in this reading's group (superseded
  /// included), ordered by attempt; empty = a group of one.
  final List<EcgReading> attempts;
  const EcgDetailData({
    required this.reading,
    required this.packets,
    this.attempts = const [],
  });

  static Future<EcgDetailData?> load(String id) async {
    final row = await LocalDb.ecgReading(id);
    final reading = row == null ? null : EcgReading.fromRow(row);
    if (reading == null) return null;
    final packets = (await LocalDb.ecgReadingPackets(
      id,
    )).map(EcgPacketCodec.fromRow).toList();
    final attempts = [
      for (final a in await LocalDb.ecgAttempts(id)) ?EcgReading.fromRow(a),
    ];
    return EcgDetailData(
      reading: reading,
      packets: packets,
      attempts: attempts,
    );
  }
}

class EcgDetailScreen extends StatefulWidget {
  final EcgDetailData data;

  /// Design 04 seams: deleting the whole attempt group (default
  /// LocalDb.deleteEcgReading), and the export path.
  final Future<void> Function(String id)? onDelete;
  final LogResultSaver? saveLog;
  final EcgReadingSource? exportSource;
  final EcgExportEnv? exportEnv;
  const EcgDetailScreen({
    super.key,
    required this.data,
    this.onDelete,
    this.saveLog,
    this.exportSource,
    this.exportEnv,
  });

  @override
  State<EcgDetailScreen> createState() => _EcgDetailScreenState();
}

/// The message the coach receives for "Analyze now" — sent visibly as the
/// user's own turn; the model must call `get_ecg_reading` itself.
String ecgAnalyzePrompt(String id) =>
    'Analyse my ECG reading $id. Use get_ecg_reading. Start with its outcome '
    'and the band-reported result; if the outcome says no rhythm may be read, '
    'say why and stop there. Otherwise read the waveform itself — rate, '
    'rhythm and its regularity, intervals and morphology — and give your '
    'impression. Say where the trace or its unproven polarity does not '
    'support a reading, and say so if you disagree with the band.';

class _EcgDetailScreenState extends State<EcgDetailScreen> {
  static const _scales = [40.0, 80.0, 160.0, 320.0];
  int _scale = 1;
  bool _detailsOpen = false;
  bool _timelineOpen = false;
  bool _exporting = false;
  String? _exportFailure;

  @override
  void didUpdateWidget(EcgDetailScreen old) {
    super.didUpdateWidget(old);
    // A different reading starts closed: its Details are its own.
    if (!identical(old.data, widget.data)) {
      _detailsOpen = false;
      _timelineOpen = false;
      _exportFailure = null;
    }
  }

  Future<void> _analyze(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final id = widget.data.reading.id;
    if (!coachReadyNow(c)) {
      await Navigator.of(
        c,
      ).push(themedRoute((_) => const CoachSetup(), name: 'CoachSetup'));
      if (!c.mounted || !coachReadyNow(c)) return;
    }
    final cfg = c.read<CoachConfig>();
    if (!cfg.isLocalEndpoint) {
      final host = Uri.tryParse(cfg.apiBase)?.host ?? cfg.apiBase;
      final ok = await showDialog<bool>(
        context: c,
        builder: (dc) => AlertDialog(
          title: Text(
            l?.ecgAnalyzeCloudTitle ?? 'Send this reading to your model?',
          ),
          content: Text(
            l?.ecgAnalyzeCloudBody(host, cfg.model) ??
                'The reading summary and the full waveform (every sample the '
                    'band recorded, 100 per second) will be sent to $host as '
                    '${cfg.model}. No raw frames, no band serial.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(false),
              child: Text(l?.ecgCancel ?? 'Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dc).pop(true),
              child: Text(l?.ecgContinue ?? 'Continue'),
            ),
          ],
        ),
      );
      if (ok != true || !c.mounted) return;
    }
    await Navigator.of(c).push(
      themedRoute(
        (_) => CoachScreen(
          initialMessage: ecgAnalyzePrompt(id),
          startNewSession: true,
        ),
        name: 'CoachScreen',
      ),
    );
  }

  Future<void> _delete(BuildContext c) async {
    final l = AppLocalizations.of(c);
    // Deleting any attempt deletes the whole group (design 04 R2), so the
    // dialog counts it: N = rows in the group, at least this one.
    final n = widget.data.attempts.isEmpty ? 1 : widget.data.attempts.length;
    final ok = await showDialog<bool>(
      context: c,
      builder: (dc) => AlertDialog(
        title: Text(
          n == 1
              ? (l?.ecgDeleteConfirmOne ?? 'Delete this reading?')
              : (l?.ecgDeleteConfirmMany(n) ??
                    'Delete this reading and all $n attempts?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(false),
            child: Text(l?.ecgCancel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dc).pop(true),
            child: Text(l?.ecgDeleteConfirm ?? 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !c.mounted) return;
    final id = widget.data.reading.id;
    await (widget.onDelete ?? (x) => LocalDb.deleteEcgReading(x))(id);
    if (c.mounted) Navigator.of(c).pop();
  }

  /// Export this reading's whole attempt group as one log file. The busy flag
  /// is cleared in `finally` (AGENTS 4.3); a failure stays on screen.
  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportFailure = null;
    });
    String? failure;
    try {
      failure = await _runEcgExport(
        env: widget.exportEnv,
        source: widget.exportSource,
        save: widget.saveLog,
        readingId: widget.data.reading.id,
      );
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportFailure = failure;
        });
      }
    }
  }

  Future<void> _openAttempt(BuildContext c, String id) async {
    final data = await EcgDetailData.load(id);
    if (!c.mounted || data == null) return;
    await Navigator.of(c).push(
      themedRoute((_) => EcgDetailScreen(data: data), name: 'EcgDetailScreen'),
    );
  }

  /// The words after "No rhythm reading to analyze —": why nothing may be read.
  String _noRhythmWhy(AppLocalizations? l, EcgOutcome o) => switch (o.kind) {
    EcgOutcomeKind.notReadable => [
      for (final r in o.reasons) ecgReasonText(l, r),
    ].join(', '),
    _ => ecgOutcomeLabel(l, o),
  };

  /// The Details accordion: every number and rule the outcome was decided on.
  /// Always available (not tied to any display setting); rows are built only
  /// while it is open.
  List<Widget> _detailRows(BuildContext c, EcgOutcome o) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final r = widget.data.reading;
    final packets = widget.data.packets;
    final notRecorded = l?.ecgNotRecorded ?? 'not recorded';
    final none = l?.ecgDetailNone ?? 'none';
    // A value the row does not hold reads "not recorded", never a guess.
    String opt(Object? v) => v == null ? notRecorded : '$v';
    String maskText(int m) => m == 0
        ? none
        : '${ecgReasonLabels(l, m).join(', ')} (0x${m.toRadixString(16).padLeft(2, '0')})';
    String offsetText(int m) {
      final a = m.abs();
      final hh = (a ~/ 60).toString().padLeft(2, '0');
      final mm = (a % 60).toString().padLeft(2, '0');
      return '${m < 0 ? '-' : '+'}$hh:$mm ($m min)';
    }

    final now = kEcgOutcomeTableVersion;
    final captured = r.captureTableVersion;
    final tableText = captured == null
        ? (l?.ecgDetailTableNotRecorded(now) ??
              'not recorded; shown now with table v$now')
        : captured == now
        ? (l?.ecgDetailTableSame(now) ?? 'v$now (captured and shown now)')
        : (l?.ecgDetailTableBoth(captured, now) ??
              'captured with table v$captured, shown now with table v$now');

    Widget row(String field, String label, String value) => Padding(
      key: ValueKey('ecg-detail:$field'),
      padding: const EdgeInsets.symmetric(vertical: S.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(label, style: F.cap.copyWith(color: p.ink2)),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: F.cap.copyWith(color: p.ink),
            ),
          ),
        ],
      ),
    );

    final group = widget.data.attempts;
    return [
      row(
        'outcome',
        l?.ecgDetailOutcome ?? 'What the app decided',
        [
          ecgOutcomeLabel(l, o),
          for (final x in o.reasons) '· ${ecgReasonText(l, x)}',
        ].join('\n'),
      ),
      row('result_code', l?.ecgDetailResultCode ?? 'Band result code', '${r.resultCode}'),
      row(
        'category',
        l?.ecgDetailStoredCategory ?? 'Band category as stored',
        ecgCategoryLabel(l, r.category),
      ),
      row(
        'avg_hr',
        l?.ecgDetailAvgHr ?? 'Average heart rate (decides)',
        opt(r.avgHr == null ? null : '${r.avgHr} bpm'),
      ),
      row(
        'live_hr',
        l?.ecgDetailLiveHr ?? 'Live heart rate (never decides)',
        opt(r.liveHr == null ? null : '${r.liveHr} bpm'),
      ),
      row(
        'quality',
        l?.ecgQuality ?? 'Signal quality',
        r.quality == null
            ? notRecorded
            : (l?.ecgDetailQualityValue('${r.quality}') ??
                  '${r.quality} · band-reported, scale unknown'),
      ),
      row(
        'unreadable_mask',
        l?.ecgDetailFinalMask ?? 'Band reasons, final second',
        maskText(r.unreadableMask),
      ),
      row(
        'mask_any',
        l?.ecgDetailMaskAny ?? 'Band reasons, any second',
        r.maskAny == null ? notRecorded : maskText(r.maskAny!),
      ),
      row(
        'variability_raw',
        l?.ecgDetailVariability ?? 'Variability (raw, unit unknown)',
        opt(r.variabilityRaw),
      ),
      row(
        'min_uv',
        l?.ecgDetailMin ?? 'Lowest sample',
        opt(r.minUv == null ? null : '${r.minUv} µV'),
      ),
      row(
        'max_uv',
        l?.ecgDetailMax ?? 'Highest sample',
        opt(r.maxUv == null ? null : '${r.maxUv} µV'),
      ),
      row(
        'rms_uv',
        l?.ecgDetailRms ?? 'RMS amplitude',
        opt(r.rmsUv == null ? null : '${r.rmsUv!.toStringAsFixed(1)} µV'),
      ),
      row('sample_count', l?.ecgDetailSampleCount ?? 'Samples', '${r.sampleCount}'),
      row(
        'missing_segments',
        l?.ecgMissingSegments ?? 'Missing segments',
        '${r.missingSegments}',
      ),
      row(
        'interruptions',
        l?.ecgInterruptions ?? 'Interruptions',
        '${r.interruptions}',
      ),
      row(
        'stop_reason',
        l?.ecgDetailStopReason ?? 'Stopped because',
        r.stopReason == null
            ? (r.status == EcgReadingStatus.partial ? notRecorded : none)
            : '${r.stopReason}: ${ecgStopReasonLabel(r.stopReason)}',
      ),
      row(
        'firmware_version',
        l?.ecgDetailFirmware ?? 'Band firmware',
        opt(r.firmwareVersion),
      ),
      row(
        'capture_app_version',
        l?.ecgDetailAppVersion ?? 'App version at capture',
        opt(r.captureAppVersion),
      ),
      row(
        'capture_table_version',
        l?.ecgDetailTableVersion ?? 'Rule table version',
        tableText,
      ),
      row(
        'start_offset_min',
        l?.ecgDetailUtcOffset ?? 'UTC offset at capture',
        r.startOffsetMin == null
            ? notRecorded
            : offsetText(r.startOffsetMin!),
      ),
      row(
        'packets',
        l?.ecgDetailPackets ?? 'Kept waveform',
        packets.isEmpty
            ? (l?.ecgNotKept ?? 'not kept')
            : (l?.ecgDetailPacketsKept(packets.length) ??
                  '${packets.length} seconds kept'),
      ),
      _timeline(c),
      if (group.length > 1) ...[
        Padding(
          padding: const EdgeInsets.only(top: S.x3, bottom: S.x1),
          child: Text(
            l?.ecgDetailAttempts ?? 'Attempts in this group',
            style: F.cap.copyWith(color: p.ink3),
          ),
        ),
        for (var i = 0; i < group.length; i++)
          Pressable(
            key: ValueKey('ecg-attempt:${group[i].id}'),
            semanticLabel: l?.ecgAttemptLine(
                  group[i].attempt ?? i + 1,
                  ecgReadingLabel(l, group[i]),
                ) ??
                'Attempt ${group[i].attempt ?? i + 1}',
            onTap: group[i].id == r.id
                ? null
                : () => _openAttempt(c, group[i].id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${l?.ecgAttemptLine(group[i].attempt ?? i + 1, ecgReadingLabel(l, group[i])) ?? 'Attempt ${group[i].attempt ?? i + 1}: ${ecgReadingLabel(l, group[i])}'}'
                      ' · ${_fmtWhen(group[i].startTs)}'
                      '${group[i].id == r.id ? ' · ${l?.ecgAttemptThis ?? 'this reading'}' : ''}',
                      style: F.cap.copyWith(color: p.ink),
                    ),
                  ),
                  if (group[i].id != r.id)
                    Icon(LucideIcons.chevronRight, size: 14, color: p.ink3),
                ],
              ),
            ),
          ),
      ],
      Padding(
        key: const ValueKey('ecg-detail:band-logic'),
        padding: const EdgeInsets.only(top: S.x3),
        child: Text(
          l?.ecgDetailBandLogic ??
              'How the band decides its result is proprietary and unknown to '
                  'this app. The app only reads the numbers the band reports.',
          style: F.cap.copyWith(color: p.ink2, height: 1.4),
        ),
      ),
      Padding(
        key: const ValueKey('ecg-detail:rules'),
        padding: const EdgeInsets.only(top: S.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in [
              (l ?? lookupAppLocalizations(const Locale('en'))).ecgRateMapping,
              l?.ecgDetailRuleHr ??
                  'The heart rate that decides is the average heart rate the '
                      'band reports. The live rate is shown but never decides.',
              l?.ecgDetailRuleMask ??
                  'Any reason bit the band set in any second, an unknown '
                      'result code or a missing heart rate makes the reading '
                      'Not readable, whatever the result code says.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: S.x1),
                child: Text(t, style: F.cap.copyWith(color: p.ink2, height: 1.4)),
              ),
          ],
        ),
      ),
    ];
  }

  /// The per-second timeline of a kept waveform: what each second's own header
  /// bytes said, read through the one decoder (ecgSecondOf). A collapsible
  /// table; "not kept" when the waveform was not kept.
  Widget _timeline(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final packets = widget.data.packets;
    final title = l?.ecgTimelineTitle ?? 'Per-second timeline';
    if (packets.isEmpty) {
      return Padding(
        key: const ValueKey('ecg-detail:timeline'),
        padding: const EdgeInsets.symmetric(vertical: S.x1),
        child: Row(
          children: [
            Expanded(child: Text(title, style: F.cap.copyWith(color: p.ink2))),
            Text(
              l?.ecgNotKept ?? 'not kept',
              style: F.cap.copyWith(color: p.ink),
            ),
          ],
        ),
      );
    }
    final yes = l?.investigateYes ?? 'yes';
    final no = l?.investigateNo ?? 'no';
    final none = l?.ecgDetailNone ?? 'none';
    TableRow line(List<String> cells, {bool head = false}) => TableRow(
      children: [
        for (final t in cells)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Text(
              t,
              style: F.cap.copyWith(
                color: head ? p.ink3 : p.ink,
                fontWeight: head ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
      ],
    );
    return Column(
      key: const ValueKey('ecg-detail:timeline'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pressable(
          key: const ValueKey('ecg-timeline-toggle'),
          semanticLabel: title,
          onTap: () => setState(() => _timelineOpen = !_timelineOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x1),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$title (${packets.length})',
                    style: F.cap.copyWith(color: p.on(C.blue)),
                  ),
                ),
                Icon(
                  _timelineOpen
                      ? LucideIcons.chevronUp
                      : LucideIcons.chevronDown,
                  size: 14,
                  color: p.ink3,
                ),
              ],
            ),
          ),
        ),
        if (_timelineOpen)
          Table(
            key: const ValueKey('ecg-timeline-table'),
            columnWidths: const {
              0: FixedColumnWidth(34),
              1: FixedColumnWidth(50),
              2: FixedColumnWidth(54),
              3: FixedColumnWidth(54),
              5: FixedColumnWidth(62),
            },
            children: [
              line([
                l?.ecgTimelineSecond ?? 'Sec',
                l?.ecgTimelineQuality ?? 'Quality',
                l?.ecgTimelineContact ?? 'Contact',
                l?.ecgTimelineS2 ?? 'S2',
                l?.ecgTimelineReasons ?? 'Reasons',
                l?.ecgTimelineProgress ?? 'Progress',
              ], head: true),
              for (final sec in ecgSecondsOf(packets))
                if (sec.placeholder)
                  line([
                    '${sec.ordinal + 1}',
                    l?.ecgTimelineMissing ?? 'missing second',
                    '',
                    '',
                    '',
                    '',
                  ])
                else if (!sec.decoded)
                  line([
                    '${sec.ordinal + 1}',
                    l?.ecgTimelineUndecodable ?? 'not decodable',
                    '',
                    '',
                    '',
                    '',
                  ])
                else
                  line([
                    '${sec.ordinal + 1}',
                    '${sec.quality}',
                    sec.presence == true ? yes : no,
                    '${sec.s2State}/${sec.currentS2One == true ? 1 : 0}',
                    (sec.mask ?? 0) == 0
                        ? none
                        : ecgReasonLabels(l, sec.mask!).join(', '),
                    '${sec.progress}%',
                  ]),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final r = widget.data.reading;
    final packets = widget.data.packets;
    final px = _scales[_scale];
    final o = ecgOutcome(r);
    final partial = o.kind == EcgOutcomeKind.partial;
    Widget kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x1),
      child: Row(
        children: [
          Expanded(
            child: Text(k, style: F.body.copyWith(color: p.ink2)),
          ),
          Text(v, style: F.body.copyWith(color: p.ink)),
        ],
      ),
    );
    final canAnalyze = o.kind == EcgOutcomeKind.bandResult && packets.isNotEmpty;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(backgroundColor: p.bg, title: Text(l?.ecgTitle ?? 'ECG')),
      body: ListView(
        padding: pad,
        children: [
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (partial) ...[
                  Text(
                    'Partial reading',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                  const SizedBox(height: S.x1),
                  Text(
                    ecgOutcomeLabel(l, o),
                    style: F.t2.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: S.x1),
                  Text(_fmtWhen(r.startTs), style: F.cap.copyWith(color: p.ink3)),
                  if (ecgStopReasonLabel(r.stopReason).isNotEmpty) ...[
                    const SizedBox(height: S.x2),
                    Text(
                      ecgStopReasonLabel(r.stopReason),
                      style: F.body.copyWith(color: p.ink),
                    ),
                  ],
                  const SizedBox(height: S.x3),
                  Text(
                    'It was not screened, so there is no rhythm result.',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ] else ...[
                  Text(
                    l?.ecgBandReported ?? 'Band-reported result',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                  const SizedBox(height: S.x1),
                  Text(ecgOutcomeLabel(l, o), style: F.t2.copyWith(color: p.ink)),
                  const SizedBox(height: S.x1),
                  Text(_fmtWhen(r.startTs), style: F.cap.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x2),
                  _EcgOutcomeBlock(outcome: o, showLabel: false),
                  const SizedBox(height: S.x3),
                  Text(
                    l?.ecgNotDiagnosis ??
                        'The category comes from the band. This is a screen, not a medical test.',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ],
                Pressable(
                  key: const ValueKey('ecg-screener-link'),
                  semanticLabel: 'What the results mean',
                  onTap: () => go(c, const EcgScreenerScreen()),
                  child: Padding(
                    padding: const EdgeInsets.only(top: S.x3),
                    child: Text(
                      'What the results mean',
                      style: F.cap.copyWith(
                        color: p.on(C.blue),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: S.x4),
          Section(
            l?.ecgWaveformLabel ??
                'Accepted waveform, microvolts as the band sent them. Gaps are '
                    'missing seconds.',
            packets.isEmpty
                ? StatusCard(
                    l?.ecgWaveformEmpty ??
                        'No waveform was saved with this reading.',
                    '',
                    icon: LucideIcons.activity,
                  )
                : Surface(
                    pad: const EdgeInsets.all(S.x3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '±${EcgWaveformPainter.rangeFor(packets)} µV',
                              style: F.cap.copyWith(color: p.ink3),
                            ),
                            const Spacer(),
                            Pressable(
                              semanticLabel: l?.ecgZoomOut ?? 'Zoom out',
                              onTap: _scale > 0
                                  ? () => setState(() => _scale--)
                                  : null,
                              child: Icon(
                                LucideIcons.zoomOut,
                                size: 20,
                                color: p.ink2,
                              ),
                            ),
                            const SizedBox(width: S.x3),
                            Pressable(
                              semanticLabel: l?.ecgZoomIn ?? 'Zoom in',
                              onTap: _scale < _scales.length - 1
                                  ? () => setState(() => _scale++)
                                  : null,
                              child: Icon(
                                LucideIcons.zoomIn,
                                size: 20,
                                color: p.ink2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: S.x2),
                        SizedBox(
                          height: 180,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                size: Size(
                                  EcgWaveformPainter.widthFor(packets, px),
                                  180,
                                ),
                                painter: EcgWaveformPainter(
                                  packets: packets,
                                  pxPerSecond: px,
                                  color: C.domHealth,
                                  grid: p.line,
                                  gap: p.wash(C.orange),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: S.x2),
                        Text(
                          l?.ecgSampleNote(r.sampleCount, kEcgSampleRateHz) ??
                              '${r.sampleCount} samples at $kEcgSampleRateHz Hz, '
                                  'filtered, input-referred µV. No lead or '
                                  'polarity is claimed.',
                          style: F.cap.copyWith(color: p.ink3),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: S.x4),
          Surface(
            child: Column(
              children: [
                // A rate beside "Not readable" is a number the recording does
                // not support; it is listed in Details with everything else.
                if (o.kind != EcgOutcomeKind.notReadable)
                  EcgMetricsList(metrics: ecgMetricsOf(r)),
                kv(l?.ecgDuration ?? 'Duration', '${r.durationS} s'),
                kv(
                  l?.ecgInterruptions ?? 'Interruptions',
                  '${r.interruptions}',
                ),
                kv(
                  l?.ecgMissingSegments ?? 'Missing segments',
                  '${r.missingSegments}',
                ),
                kv(l?.ecgWristLabel ?? 'Wrist', _wristLabel(l, r.wrist)),
              ],
            ),
          ),
          const SizedBox(height: S.x4),
          // Coach: one rule for the button and the get_ecg_reading tool. Only a
          // band result with its waveform kept can be analysed; otherwise the
          // control is ABSENT and a line says why.
          if (canAnalyze) ...[
            ActionCard(
              l?.ecgAnalyzeNow ?? 'Analyze now',
              l?.ecgBandReported ?? 'Band-reported result',
              l?.ecgAnalyzeNow ?? 'Analyze now',
              LucideIcons.sparkles,
              kCoachAccent,
              onTap: () => _analyze(c),
            ),
          ] else
            Text(
              o.kind == EcgOutcomeKind.bandResult
                  ? (l?.ecgWaveformNotKept ?? 'Waveform not kept')
                  : (l?.ecgCoachNoRhythm(_noRhythmWhy(l, o)) ??
                        'No rhythm reading to analyze — ${_noRhythmWhy(l, o)}'),
              style: F.cap.copyWith(color: p.ink3, height: 1.4),
            ),
          const SizedBox(height: S.x4),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Pressable(
                  key: const ValueKey('ecg-details'),
                  semanticLabel: l?.ecgDetails ?? 'Details',
                  onTap: () => setState(() => _detailsOpen = !_detailsOpen),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x1),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l?.ecgDetails ?? 'Details',
                            style: F.head.copyWith(color: p.ink),
                          ),
                        ),
                        Icon(
                          _detailsOpen
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                          size: 18,
                          color: p.ink3,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_detailsOpen) ..._detailRows(c, o),
              ],
            ),
          ),
          const SizedBox(height: S.x3),
          _ExportRow(
            buttonKey: const ValueKey('ecg-export-reading'),
            label: l?.ecgExportReading ?? 'Export this reading',
            busy: _exporting,
            onTap: _export,
            failure: _exportFailure,
          ),
          const SizedBox(height: S.x2),
          Pressable(
            semanticLabel: l?.ecgDelete ?? 'Delete reading',
            onTap: () => _delete(c),
            child: Padding(
              padding: const EdgeInsets.all(S.x3),
              child: Text(
                l?.ecgDelete ?? 'Delete reading',
                textAlign: TextAlign.center,
                style: F.body.copyWith(color: C.red),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
