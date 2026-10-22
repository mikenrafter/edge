import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';

/// The shared export and clear actions for the persistent developer log.
class DevLogActions extends StatefulWidget {
  const DevLogActions({
    super.key,
    this.export,
    this.clear,
    this.shareLabel = 'Share dev log (ZIP)',
    this.clearLabel = 'Clear dev log',
    this.shareKey = const ValueKey('dev-log-export'),
    this.clearKey = const ValueKey('dev-log-clear'),
  });

  final Future<bool> Function(Rect origin)? export;
  final Future<void> Function()? clear;
  final String shareLabel, clearLabel;
  final Key shareKey, clearKey;

  @override
  State<DevLogActions> createState() => _DevLogActionsState();
}

class _DevLogActionsState extends State<DevLogActions> {
  bool _busy = false;

  void _say(ScaffoldMessengerState messenger, String text) {
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      content: Text(text),
    ));
  }

  Future<void> _export(BuildContext context) async {
    if (_busy || widget.export == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final origin = shareOrigin(context);
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.export!(origin);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    if (!ok && mounted) _say(messenger, 'Could not export the dev log.');
  }

  Future<void> _clear(BuildContext context) async {
    if (_busy || widget.clear == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final yes = await confirmRemove(
      context,
      title: 'Clear the dev log?',
      body: 'Every saved day of the dev log, and the old sync log if it is '
          'still there, is deleted from this phone. Anything you exported '
          'stays where you sent it. There is no undo.',
      remove: 'Clear',
    );
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    var ok = true;
    try {
      await widget.clear!();
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _busy = false);
    if (mounted) {
      _say(messenger, ok ? 'Dev log cleared' : 'Could not clear the dev log.');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.export != null)
            Padding(
              padding: const EdgeInsets.only(top: S.x3),
              child: BigButton(
                widget.shareLabel,
                key: widget.shareKey,
                icon: LucideIcons.download,
                soft: true,
                color: C.blue,
                onTap: _busy ? null : () => _export(context),
              ),
            ),
          if (widget.clear != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: BigButton(
                widget.clearLabel,
                key: widget.clearKey,
                icon: LucideIcons.trash2,
                soft: true,
                color: C.red,
                onTap: _busy ? null : () => _clear(context),
              ),
            ),
        ],
      );
}

class DevLogsPage extends StatelessWidget {
  const DevLogsPage({super.key, this.export, this.clear});
  final Future<bool> Function(Rect origin)? export;
  final Future<void> Function()? clear;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: P.of(context).bg,
        appBar: AppBar(title: const Text('Logs')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(S.x4),
            children: [
              Text(
                'Kept on the phone, one file a day for the last 7 days, in the '
                "app's files folder under dev_log, so it survives an update. "
                'Alarm, wake and sync lines are always kept; the rest only '
                'while developer mode is on. The export is one ZIP with those '
                'files and the recent wake trace.',
                style: F.cap.copyWith(color: P.of(context).ink2, height: 1.4),
              ),
              DevLogActions(
                export: export,
                clear: clear,
                shareLabel: 'Share dev log (ZIP)',
                shareKey: const ValueKey('dev-logs-share'),
                clearKey: const ValueKey('dev-logs-clear'),
              ),
            ],
          ),
        ),
      );
}
