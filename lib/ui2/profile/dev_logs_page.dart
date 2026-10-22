import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../sync/dev_log.dart';
import '../../sync/dev_log_export.dart';
import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';

/// What the dev log's Share and Clear buttons act on. An interface, not two
/// callbacks, so the buttons' calls resolve to a declared method (the heavy
/// guard counts an unresolved callback invocation as new work).
abstract class DevLogActionsPort {
  /// Shares the dev log as one ZIP; true when the share ran.
  Future<bool> export(Rect origin);

  /// Deletes the saved dev log. The confirm is the caller's.
  Future<void> clear();
}

/// The real dev log: the share sheet and `DevLog.instance`.
class DeviceDevLogPort implements DevLogActionsPort {
  const DeviceDevLogPort();

  @override
  Future<bool> export(Rect origin) =>
      shareDevLog(DevLog.instance, origin: origin);

  @override
  Future<void> clear() => DevLog.instance.clear();
}

/// English fallback for the description when no localizations are mounted.
const devLogsDescriptionEn =
    "Kept on the phone, one file a day for the last 7 days, in the app's "
    'files folder under dev_log, so it survives an update. Alarm, wake and '
    'sync lines are always kept; the rest only while developer mode is on. '
    'The export is one ZIP with those files and the recent wake trace.';

/// The shared export and clear actions for the persistent developer log.
class DevLogActions extends StatefulWidget {
  const DevLogActions({
    super.key,
    this.port,
    this.shareLabel = 'Share dev log (ZIP)',
    this.clearLabel,
    this.shareKey = const ValueKey('dev-log-export'),
    this.clearKey = const ValueKey('dev-log-clear'),
  });

  /// Null: no dev log to act on, so no buttons.
  final DevLogActionsPort? port;
  final String shareLabel;

  /// Null: the shared localized label.
  final String? clearLabel;
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
    final port = widget.port;
    if (_busy || port == null) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final origin = shareOrigin(context);
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await port.export(origin);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    if (!ok && mounted) {
      _say(messenger,
          l?.devLogsExportFailed ?? 'Could not export the dev log.');
    }
  }

  Future<void> _clear(BuildContext context) async {
    final port = widget.port;
    if (_busy || port == null) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final yes = await confirmRemove(
      context,
      title: l?.devLogsClearConfirmTitle ?? 'Clear the dev log?',
      body: l?.devLogsClearConfirmBody ??
          'Every saved day of the dev log, and the old sync log if it is '
              'still there, is deleted from this phone. Anything you exported '
              'stays where you sent it. There is no undo.',
      remove: l?.devLogsClearAction ?? 'Clear',
      keep: l?.devLogsKeepAction ?? 'Keep it',
    );
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    var ok = true;
    try {
      await port.clear();
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _busy = false);
    if (mounted) {
      _say(
          messenger,
          ok
              ? l?.devLogsCleared ?? 'Dev log cleared'
              : l?.devLogsClearFailed ?? 'Could not clear the dev log.');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.port != null)
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
          if (widget.port != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: BigButton(
                widget.clearLabel ??
                    AppLocalizations.of(context)?.devLogsClearLabel ??
                    'Clear dev log',
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
  const DevLogsPage({super.key, this.port = const DeviceDevLogPort()});
  final DevLogActionsPort? port;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: P.of(context).bg,
        appBar: AppBar(
            title: Text(
                AppLocalizations.of(context)?.settingsLogsRowTitle ?? 'Logs')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(S.x4),
            children: [
              Text(
                AppLocalizations.of(context)?.devLogsDescription ??
                    devLogsDescriptionEn,
                style: F.cap.copyWith(color: P.of(context).ink2, height: 1.4),
              ),
              DevLogActions(
                port: port,
                shareLabel: AppLocalizations.of(context)?.devLogsShareLabel ??
                    'Share dev log (ZIP)',
                shareKey: const ValueKey('dev-logs-share'),
                clearKey: const ValueKey('dev-logs-clear'),
              ),
            ],
          ),
        ),
      );
}
