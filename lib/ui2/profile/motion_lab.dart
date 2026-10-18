// The Device lab's Motion tab: record the band's six-axis IMU stream for a few
// seconds, review it, and save it as a file.
//
// The wearer says what they are about to do (kind, label, wrist, mounting,
// posture, environment, how long) and presses Arm. The next double tap begins
// the recording and the lab asks for the IMU stream through the app's one
// stream-ownership seam; this screen never writes a band command. While it is
// armed or recording, normal double-tap actions are paused. A finished capture
// sits in memory until "Save recording" writes it under
// `device_lab/imu/<id>.jsonl`; nothing is saved on its own. Leaving the tab
// while armed or recording cancels it and lets go of the stream.
//
// The idle form folds; the armed / recording / review card sits outside the
// fold so folding can never hide the control that ends a recording. Saved
// recordings are listed with Share and Delete.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/imu_recorder.dart';
import '../../gestures/imu_recording.dart';
import '../../gestures/imu_recording_store.dart';
import '../../util/log_file.dart' show shareFileCopy;
import '../activity/share.dart' show shareOrigin;
import '../screens/journal_compose.dart' show OsTextField;
import '../ui2.dart';
import 'profile.dart' show SettingsAccordion;

/// How a saved file is shared; null is [shareFileCopy] with the JSON type.
/// True when the share ran. [origin] anchors the iPad popover.
typedef ImuFileSharer = Future<bool> Function(String path, Rect? origin);

class MotionLabPanel extends StatefulWidget {
  const MotionLabPanel({
    super.key,
    required this.recorder,
    required this.store,
    this.share,
  });

  final ImuLabRecorder recorder;
  final ImuRecordingStore store;
  final ImuFileSharer? share;

  @override
  State<MotionLabPanel> createState() => _MotionLabPanelState();
}

class _MotionLabPanelState extends State<MotionLabPanel> {
  // The form.
  ImuRecordingKind _kind = ImuRecordingKind.action;
  final _label = TextEditingController();
  final _mounting = TextEditingController();
  ImuWrist? _wrist;
  String? _posture;
  String? _environment;
  int? _seconds; // null: the kind's default

  // The review.
  SavedImuRecording? _savedAs;
  bool _busy = false;
  String? _message;

  // The saved list.
  List<SavedImuRecording>? _saved;
  String? _listError;
  bool _exporting = false;

  static const _postures = [
    ('sitting', 'Sitting'),
    ('standing', 'Standing'),
    ('lying', 'Lying down'),
    ('walking', 'Walking'),
    ('raised', 'Arm raised'),
  ];
  static const _environments = [
    ('still', 'Still room'),
    ('car', 'Car'),
    ('plane', 'Plane'),
    ('outside', 'Walking outside'),
    ('cleaning', 'Cleaning'),
  ];
  static const _minSeconds = 5;
  static const _stepSeconds = 5;

  late final ImuLabRecorder _recorder = widget.recorder;

  int get _duration => _seconds ?? ImuLabSetup.defaultSeconds(_kind);

  bool get _canArm => _label.text.trim().isNotEmpty && _wrist != null;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_changed);
    _label.addListener(_changed);
    _loadSaved();
  }

  @override
  void dispose() {
    _recorder.removeListener(_changed);
    // Leaving the tab ends an armed or running recording and lets go of the
    // stream. A finished capture stays with the recorder for the next visit.
    _recorder.cancel();
    _label.dispose();
    _mounting.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSaved() async {
    try {
      final list = await widget.store.list();
      if (!mounted) return;
      setState(() {
        _saved = list;
        _listError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _listError = 'Could not read the saved recordings.');
    }
  }

  void _arm() {
    _message = null;
    _savedAs = null;
    _recorder.arm(ImuLabSetup.seconds(
      kind: _kind,
      seconds: _duration,
      label: _label.text.trim(),
      wrist: _wrist,
      mounting: _mounting.text.trim(),
      posture: _label2(_postures, _posture),
      environment: _label2(_environments, _environment),
    ));
  }

  static String _label2(List<(String, String)> options, String? id) {
    for (final o in options) {
      if (o.$1 == id) return o.$2;
    }
    return '';
  }

  Future<void> _save() async {
    final rec = _recorder.recording;
    if (rec == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.store.save(rec);
      if (!mounted) return;
      setState(() {
        _savedAs = saved;
        _message = 'Saved to device_lab/imu/${saved.id}.jsonl';
      });
      await _loadSaved();
    } catch (_) {
      if (!mounted) return;
      setState(() => _message =
          'Could not save the recording. It is still here, so you can try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext c, String path) async {
    // Read before the await.
    final origin = shareOrigin(c);
    var ok = false;
    try {
      ok = await (widget.share?.call(path, origin) ??
          shareFileCopy(path, origin: origin));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _message =
        ok ? null : 'Could not open the share sheet. The file is still saved.');
  }

  Future<void> _exportAll(BuildContext c) async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _message = null;
    });
    try {
      final archive = await widget.store.exportAll();
      if (!mounted || !c.mounted) return;
      final origin = shareOrigin(c);
      var ok = false;
      try {
        ok = await (widget.share?.call(archive.path, origin) ??
            shareFileCopy(archive.path,
                mimeType: 'application/zip',
                subject: 'OpenStrap motion recordings',
                origin: origin));
      } catch (_) {}
      if (!mounted) return;
      setState(() => _message = ok
          ? null
          : 'Could not open the share sheet for the export.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = 'Could not prepare the recordings export.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _delete(BuildContext c, SavedImuRecording s) async {
    final yes = await confirmRemove(
      c,
      title: 'Delete this recording?',
      body: '${s.id}.jsonl is removed from this phone. Anything you shared '
          'stays where you sent it. There is no undo.',
      remove: 'Delete',
    );
    if (!yes || !mounted) return;
    try {
      await widget.store.delete(s.id);
      if (!mounted) return;
      setState(() => _message = null);
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = 'Could not delete ${s.id}.jsonl.');
      return;
    }
    await _loadSaved();
  }

  void _discard() {
    _recorder.discard();
    setState(() {
      _savedAs = null;
      _message = null;
    });
    _loadSaved();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final phase = _recorder.phase;
    final note = _recorder.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsAccordion('Record motion',
            id: 'device_lab_motion_record',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Records what the band\'s motion sensors send, as it '
                      'sends it, for a few seconds. Fill this in, press Arm, '
                      'then double tap the band to begin and wait for the '
                      'band to buzz: that is the signal to move. The recording is '
                      'kept in memory until you save it as a file. Normal '
                      'double-tap actions are paused while it is armed or '
                      'recording.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.4),
                    ),
                    if (phase == ImuLabPhase.idle) ..._form(c, p),
                  ],
                ),
              ),
            ]),
        if (phase != ImuLabPhase.idle)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(child: _active(c, p, phase)),
          ),
        if (note != null && phase == ImuLabPhase.idle)
          _line(p, note, p.ink2),
        if (_message != null) _line(p, _message!, p.ink2),
        _savedSection(c, p),
      ],
    );
  }

  Widget _line(P p, String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: S.x2),
        child: Text(text, style: F.cap.copyWith(color: color, height: 1.4)),
      );

  // ── the form ──────────────────────────────────────────────────────────────

  List<Widget> _form(BuildContext c, P p) => [
        const SizedBox(height: S.x3),
        _Choices<ImuRecordingKind>(
          title: 'What is it',
          keyBase: 'motion-kind',
          options: [for (final k in ImuRecordingKind.values) (k, k.id, k.label)],
          selected: _kind,
          onSelect: (k) => setState(() => _kind = k ?? _kind),
          mustChoose: true,
        ),
        const SizedBox(height: S.x3),
        OsTextField(
          key: const ValueKey('motion-label'),
          controller: _label,
          label: 'Label',
          hint: 'What you will do, e.g. wrist rotation out',
        ),
        const SizedBox(height: S.x3),
        _Choices<ImuWrist>(
          title: 'Wrist the band is on',
          keyBase: 'motion-wrist',
          options: [for (final w in ImuWrist.values) (w, w.id, w.label)],
          selected: _wrist,
          onSelect: (w) => setState(() => _wrist = w),
        ),
        const SizedBox(height: S.x3),
        OsTextField(
          key: const ValueKey('motion-mounting'),
          controller: _mounting,
          label: 'Mounting',
          hint: 'How the band sits, e.g. logo toward the elbow',
        ),
        const SizedBox(height: S.x3),
        _Choices<String>(
          title: 'Posture',
          keyBase: 'motion-posture',
          options: [for (final o in _postures) (o.$1, o.$1, o.$2)],
          selected: _posture,
          onSelect: (v) => setState(() => _posture = v),
        ),
        const SizedBox(height: S.x3),
        _Choices<String>(
          title: 'Environment',
          keyBase: 'motion-env',
          options: [for (final o in _environments) (o.$1, o.$1, o.$2)],
          selected: _environment,
          onSelect: (v) => setState(() => _environment = v),
        ),
        const SizedBox(height: S.x3),
        _DurationRow(
          seconds: _duration,
          min: _minSeconds,
          max: ImuLabRecorder.maxDuration.inSeconds,
          step: _stepSeconds,
          onChanged: (s) => setState(() => _seconds = s),
        ),
        const SizedBox(height: S.x3),
        BigButton(
          'Arm recording',
          key: const ValueKey('motion-arm'),
          icon: LucideIcons.activity,
          soft: true,
          color: C.blue,
          onTap: _canArm ? _arm : null,
        ),
        if (!_canArm)
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text('Enter a label and choose the wrist first.',
                style: F.cap.copyWith(color: p.ink3)),
          ),
      ];

  // ── the card for an armed, running or finished recording ──────────────────

  Widget _active(BuildContext c, P p, ImuLabPhase phase) {
    switch (phase) {
      case ImuLabPhase.idle:
        return const SizedBox.shrink();
      case ImuLabPhase.armed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _banner(p, 'Double tap to begin', C.blue),
            const SizedBox(height: S.x2),
            Text(
              'Double tap the band once, then keep still until it buzzes. '
              'Recording starts when the phone hears the tap. Normal '
              'double-tap actions are paused until you stop '
              'or cancel.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
            const SizedBox(height: S.x3),
            BigButton('Cancel',
                key: const ValueKey('motion-cancel'),
                icon: LucideIcons.x,
                soft: true,
                color: C.red,
                onTap: _recorder.cancel),
          ],
        );
      case ImuLabPhase.starting:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _banner(p, 'Waiting for motion data…', C.blue),
            const SizedBox(height: S.x2),
            Text(
              'Do not move yet. The band buzzes once when its motion sensors '
              'are sending usable data; that is the signal to start. Keep '
              'the band where it is until then.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
            const SizedBox(height: S.x3),
            BigButton('Cancel',
                key: const ValueKey('motion-cancel'),
                icon: LucideIcons.x,
                soft: true,
                color: C.red,
                onTap: _recorder.cancel),
          ],
        );
      case ImuLabPhase.recording:
        final n = _recorder.packetCount;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _banner(p, 'Go — move now', C.green),
            const SizedBox(height: S.x2),
            Text(
                'Recording ${_recorder.elapsed.inSeconds} of '
                '${_recorder.setup!.duration.inSeconds} s',
                style: F.body.copyWith(color: p.ink)),
            Text('$n packet${n == 1 ? '' : 's'}',
                style: F.body.copyWith(color: p.ink)),
            const SizedBox(height: S.x3),
            BigButton(
              _recorder.motionOpen ? 'Mark motion end' : 'Mark motion start',
              key: const ValueKey('motion-mark'),
              icon: LucideIcons.flag,
              soft: true,
              color: C.blue,
              onTap: _recorder.motionOpen
                  ? _recorder.markMotionEnd
                  : _recorder.markMotionStart,
            ),
            const SizedBox(height: S.x2),
            BigButton('Stop',
                key: const ValueKey('motion-stop'),
                icon: LucideIcons.square,
                soft: true,
                color: C.red,
                onTap: _recorder.stop),
          ],
        );
      case ImuLabPhase.review:
        return _review(c, p, _recorder.recording!);
    }
  }

  Widget _banner(P p, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(vertical: S.x5, horizontal: S.x3),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: p.wash(color), borderRadius: R.rLg),
        child: Text(text,
            textAlign: TextAlign.center, style: F.t1.copyWith(color: p.ink)),
      );

  Widget _review(BuildContext c, P p, ImuRecording r) {
    final span = r.span, startup = r.startup;
    final lines = <String>[
      'Packets: ${r.packetCount}',
      if (span != null) 'Length: ${_secs(span)}',
      if (startup != null) 'Start-up: tap to first packet ${_secs(startup)}',
      if (r.tapToReady != null)
        'Start-up: tap to gyro ready ${_secs(r.tapToReady!)}',
      'Gaps: ${r.gapCount}',
      'Clipped packets: ${r.clippedCount}',
      'Partial blocks: ${r.partialCount}',
    ];
    final saved = _savedAs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(r.isComplete ? 'Recording finished' : 'Partial recording',
            style: F.head.copyWith(color: p.ink)),
        const SizedBox(height: S.x1),
        Text(r.status.label, style: F.body.copyWith(color: p.ink)),
        const SizedBox(height: S.x2),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(l, style: F.cap.copyWith(color: p.ink2)),
          ),
        if (_recorder.note != null && r.readyMarker == null && r.packetCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(
              '${_recorder.note} The band did not buzz. Nothing is saved '
              'unless you save it.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
          ),
        if (r.packetCount == 0)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(
              'The band sent no packets in time, so there is nothing to '
              'measure. The tap and the stream request are still in the file '
              'if you save it.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
          ),
        if (r.motionLeftOpen)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(
              'The motion start was never closed. It is saved as open.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
          ),
        const SizedBox(height: S.x3),
        if (saved == null) ...[
          BigButton(_busy ? 'Saving' : 'Save recording',
              key: const ValueKey('motion-save'),
              icon: LucideIcons.download,
              color: C.blue,
              onTap: _busy ? null : _save),
          const SizedBox(height: S.x2),
          BigButton('Discard',
              key: const ValueKey('motion-discard'),
              icon: LucideIcons.trash2,
              soft: true,
              color: C.red,
              onTap: _busy ? null : _discard),
        ] else ...[
          BigButton('Share file',
              key: const ValueKey('motion-share'),
              icon: LucideIcons.share2,
              color: C.blue,
              onTap: () => _share(c, saved.path)),
          const SizedBox(height: S.x2),
          BigButton('Done',
              key: const ValueKey('motion-done'),
              soft: true,
              color: C.blue,
              onTap: _discard),
        ],
      ],
    );
  }

  // ── saved recordings ──────────────────────────────────────────────────────

  Widget _savedSection(BuildContext c, P p) {
    final list = _saved;
    return SettingsAccordion('Saved recordings',
        id: 'device_lab_motion_saved',
        summary: list == null || list.isEmpty
            ? null
            : '${list.length} recording${list.length == 1 ? '' : 's'}',
        children: [
          if (_listError != null)
            _empty(p, _listError!)
          else if (list == null)
            _empty(p, 'Reading the saved recordings…')
          else if (list.isEmpty)
            _empty(p, 'No saved recordings yet.')
          else
            Column(children: [
              BigButton(_exporting ? 'Preparing export' : 'Export all',
                  key: const ValueKey('motion-export-all'),
                  icon: LucideIcons.archive,
                  color: C.blue,
                  onTap: _exporting ? null : () => _exportAll(c)),
              const SizedBox(height: S.x2),
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) Divider(color: p.line, height: 1),
                _SavedRow(
                  saved: list[i],
                  onShare: () => _share(c, list[i].path),
                  onDelete: () => _delete(c, list[i]),
                ),
              ],
            ]),
        ]);
  }

  Widget _empty(P p, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Text(text, style: F.body.copyWith(color: p.ink3)),
      );

  static String _secs(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

/// One row of pills; tapping the selected one clears it unless [mustChoose].
class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.title,
    required this.keyBase,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.mustChoose = false,
  });

  final String title;
  final String keyBase;

  /// (value, key suffix, label)
  final List<(T, String, String)> options;
  final T? selected;
  final ValueChanged<T?> onSelect;
  final bool mustChoose;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x1),
        Wrap(
          spacing: S.x2,
          runSpacing: S.x1,
          children: [
            for (final o in options)
              Pressable(
                key: ValueKey('$keyBase:${o.$2}'),
                semanticLabel: '$title: ${o.$3}'
                    '${o.$1 == selected ? ', selected' : ''}',
                onTap: () => onSelect(
                    o.$1 == selected && !mustChoose ? null : o.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: S.x3, vertical: S.x1),
                  decoration: BoxDecoration(
                    color: o.$1 == selected ? p.wash(C.blue) : p.card2,
                    borderRadius: R.rPill,
                  ),
                  child: Text(
                    o.$3,
                    style: F.cap.copyWith(
                      color: o.$1 == selected ? p.on(C.blue) : p.ink2,
                      fontWeight:
                          o.$1 == selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DurationRow extends StatelessWidget {
  const _DurationRow({
    required this.seconds,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final int seconds, min, max, step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Duration', style: F.body.copyWith(color: p.ink)),
          Text('Counted from the first packet. 5 s for an action, 30 s for '
              'an ambient baseline.',
              style: F.over.copyWith(color: p.ink3)),
        ]),
      ),
      IconButton(
        key: const ValueKey('motion-duration:-'),
        tooltip: 'Shorter',
        icon: const Icon(LucideIcons.minus, size: 18),
        onPressed: seconds - step >= min ? () => onChanged(seconds - step) : null,
      ),
      Text('$seconds s', style: F.body.copyWith(color: p.ink)),
      IconButton(
        key: const ValueKey('motion-duration:+'),
        tooltip: 'Longer',
        icon: const Icon(LucideIcons.plus, size: 18),
        onPressed: seconds + step <= max ? () => onChanged(seconds + step) : null,
      ),
    ]);
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow(
      {required this.saved, required this.onShare, required this.onDelete});

  final SavedImuRecording saved;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final label = saved.label;
    final title = saved.readable && label != null && label.isNotEmpty
        ? label
        : saved.id;
    final details = saved.readable
        ? [
            if (saved.kind != null) saved.kind!.label,
            _when(saved.createdAt!),
            if (saved.packetCount != null)
              '${saved.packetCount} packet${saved.packetCount == 1 ? '' : 's'}',
            if (saved.status != null && !saved.status!.isComplete)
              saved.status!.label,
            _size(saved.sizeBytes),
          ].join(' · ')
        : 'The header is unreadable. You can still delete it. '
            '${_size(saved.sizeBytes)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: F.body.copyWith(color: p.ink)),
                Text(details, style: F.cap.copyWith(color: p.ink3)),
              ]),
        ),
        if (saved.readable)
          IconButton(
            key: ValueKey('motion-saved-share:${saved.id}'),
            tooltip: 'Share $title',
            icon: const Icon(LucideIcons.share2, size: 18),
            onPressed: onShare,
          ),
        IconButton(
          key: ValueKey('motion-saved-delete:${saved.id}'),
          tooltip: 'Delete $title',
          icon: const Icon(LucideIcons.trash2, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }

  static String _when(DateTime utc) {
    final t = utc.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).ceil()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
