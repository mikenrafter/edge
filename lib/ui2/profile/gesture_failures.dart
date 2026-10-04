// Settings > Hardware > Gesture failures (8AK D): every gesture that failed to
// activate, newest first, dismissed ones too (marked), each with the same Save
// log file and Report actions as the Home card. [GestureFailures] is the route
// (it listens to the store on AppState); [GestureFailuresView] is the pure half
// the tests pump.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/gesture_failures.dart';
import '../../gestures/gesture_log_file.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

class GestureFailures extends StatelessWidget {
  const GestureFailures({super.key});

  @override
  Widget build(BuildContext c) {
    final store = c.read<AppState>().gestureFailures;
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) => GestureFailuresView(failures: store.all),
    );
  }
}

class GestureFailuresView extends StatefulWidget {
  const GestureFailuresView({
    super.key,
    required this.failures,
    this.onSave,
    this.onOpenLink,
  });

  /// Newest first; every one is listed.
  final List<GestureFailure> failures;

  /// Defaults to [saveGestureLog] (the platform share sheet).
  final GestureLogSaver? onSave;

  /// Defaults to [open3rdPartyLink].
  final Future<bool> Function(String url)? onOpenLink;

  @override
  State<GestureFailuresView> createState() => _GestureFailuresViewState();
}

class _GestureFailuresViewState extends State<GestureFailuresView> {
  // The failure whose last save failed, so its row can say so.
  String? _failedSaveFor;

  Future<void> _save(GestureFailure f) async {
    final ok = await saveFailureLog(context, f, widget.onSave);
    if (!mounted) return;
    setState(() => _failedSaveFor = ok ? null : f.gestureId);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _when(DateTime at) {
    final t = at.toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Gesture failures'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (widget.failures.isEmpty)
                  Surface(
                    child: Text('No gesture failures',
                        key: const ValueKey('gesture-failures-empty'),
                        style: F.body.copyWith(color: p.ink2)),
                  ),
                for (final f in widget.failures) ...[
                  _row(c, p, f),
                  const SizedBox(height: S.x3),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(BuildContext c, P p, GestureFailure f) {
    final id = f.gestureId;
    return Surface(
      key: ValueKey('gesture-failure-row:$id'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(
              f.kind == GestureFailureKind.ecg ? 'ECG gesture' : 'Double tap',
              style:
                  F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
          if (f.dismissed) ...[
            const SizedBox(width: S.x2),
            Text('Dismissed', style: F.over.copyWith(color: p.ink3)),
          ],
        ]),
        const SizedBox(height: 2),
        Text(f.reason, style: F.over.copyWith(color: p.ink2)),
        Text(_when(f.at), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x3),
        Row(children: [
          Expanded(
            child: BigButton('Save log file',
                key: ValueKey('gesture-failure-save:$id'),
                icon: LucideIcons.fileDown,
                color: C.orange,
                soft: true,
                onTap: () => _save(f)),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            child: BigButton('Report',
                key: ValueKey('gesture-failure-report:$id'),
                icon: LucideIcons.externalLink,
                color: C.indigo,
                soft: true,
                onTap: () =>
                    showGestureReportSheet(c, openLink: widget.onOpenLink)),
          ),
        ]),
        if (_failedSaveFor == id) ...[
          const SizedBox(height: S.x2),
          Text('Could not save the log file.',
              style: F.over.copyWith(color: p.on(C.red))),
        ],
      ]),
    );
  }
}
