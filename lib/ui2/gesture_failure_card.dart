// The Home card for a gesture that failed to activate (8AK D), and the report
// sheet the Settings list shares. Styled like the community nudges (a Surface,
// a 32 pt tinted glyph, a bold title, a body line, soft buttons), but it never
// snoozes on its own: it stays until Dismiss, and only the newest undismissed
// failure shows, one at a time. A dismissed failure stays listed in Settings >
// Hardware > Gesture failures.
//
// Save log file writes a .txt through the platform share sheet (never the
// clipboard); Report opens the sheet of links. Neither dismisses.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../gestures/gesture_failures.dart';
import '../gestures/gesture_log_file.dart';
import 'activity/share.dart' show shareOrigin;
import 'profile/profile.dart' show SetRow;
import 'ui2.dart';

/// "An ECG gesture failed to activate" / "A gesture failed to activate".
String gestureFailureTitle(GestureFailureKind kind) =>
    kind == GestureFailureKind.ecg
        ? 'An ECG gesture failed to activate'
        : 'A gesture failed to activate';

/// Save [f]'s log through [saver], or the share sheet anchored at [context]
/// (read before the first await, for the iPad popover). False when it failed.
Future<bool> saveFailureLog(
    BuildContext context, GestureFailure f, GestureLogSaver? saver) {
  if (saver != null) return saver(f);
  return saveGestureLog(f, origin: shareOrigin(context));
}

/// The report sheet: one line asking for a report and the GitHub issues, Discord
/// and Reddit links. A row opens its link and leaves the sheet open.
Future<void> showGestureReportSheet(
  BuildContext context, {
  Future<bool> Function(String url)? openLink,
}) {
  final p = P.of(context);
  final open = openLink ?? open3rdPartyLink;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: p.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('gesture-report-sheet'),
        padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Report a gesture failure',
                style: F.head.copyWith(color: p.ink)),
            const SizedBox(height: S.x2),
            Text(
              'A report with the saved log file helps us fix it. Please send '
              'one.',
              key: const ValueKey('gesture-report-encourage'),
              style: F.body.copyWith(color: p.ink2, height: 1.4),
            ),
            const SizedBox(height: S.x3),
            SetRow.brand(brandGlyph('assets/icons/github.svg'), C.n500,
                'GitHub issues',
                key: const ValueKey('gesture-report-github'),
                sub: 'Open an issue and attach the log file.',
                onTap: () => open('$kGithubUrl/issues')),
            SetRow.brand(brandGlyph('assets/icons/discord.svg'), C.indigo,
                'Discord',
                key: const ValueKey('gesture-report-discord'),
                sub: 'Ask and report in the community.',
                onTap: () => open(kDiscordUrl)),
            SetRow.brand(
                brandGlyph('assets/icons/reddit.svg'), C.orange, 'Reddit',
                key: const ValueKey('gesture-report-reddit'),
                sub: 'Post in r/OpenStrap.',
                onTap: () => open(kRedditUrl)),
          ],
        ),
      ),
    ),
  );
}

class GestureFailureCard extends StatefulWidget {
  const GestureFailureCard({
    super.key,
    required this.store,
    this.saveLog,
    this.openLink,
  });

  final GestureFailureStore store;

  /// Defaults to [saveGestureLog] (the platform share sheet).
  final GestureLogSaver? saveLog;

  /// Defaults to [open3rdPartyLink].
  final Future<bool> Function(String url)? openLink;

  @override
  State<GestureFailureCard> createState() => _GestureFailureCardState();
}

class _GestureFailureCardState extends State<GestureFailureCard> {
  // The failure the last save note is about: a note never outlives its card.
  String? _failedSaveFor;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
  }

  @override
  void didUpdateWidget(GestureFailureCard old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_changed);
      widget.store.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _save(GestureFailure f) async {
    final saver = widget.saveLog;
    // The share anchor is read before the await.
    final ok = await saveFailureLog(context, f, saver);
    if (!mounted) return;
    setState(() => _failedSaveFor = ok ? null : f.gestureId);
  }

  @override
  Widget build(BuildContext c) {
    final f = widget.store.newestUndismissed;
    if (f == null) return const SizedBox.shrink();
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(top: S.x5),
      child: Surface(
        key: const ValueKey('gesture-failure-card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: p.wash(C.orange), borderRadius: R.rSm),
              child: Icon(LucideIcons.triangleAlert,
                  size: 16, color: p.on(C.orange)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(gestureFailureTitle(f.kind),
                        style: F.body.copyWith(
                            color: p.ink, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      'Save the log file and report it so it can be fixed. '
                      'Dismissed failures stay in Settings under Gesture '
                      'failures.',
                      style: F.over.copyWith(color: p.ink3),
                    ),
                  ]),
            ),
          ]),
          const SizedBox(height: S.x3),
          Row(children: [
            Expanded(
              child: BigButton('Save log file',
                  key: const ValueKey('gesture-failure-save'),
                  icon: LucideIcons.fileDown,
                  color: C.orange,
                  soft: true,
                  onTap: () => _save(f)),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: BigButton('Report',
                  key: const ValueKey('gesture-failure-report'),
                  icon: LucideIcons.externalLink,
                  color: C.indigo,
                  soft: true,
                  onTap: () => showGestureReportSheet(c,
                      openLink: widget.openLink)),
            ),
          ]),
          if (_failedSaveFor == f.gestureId) ...[
            const SizedBox(height: S.x2),
            Text('Could not save the log file.',
                style: F.over.copyWith(color: p.on(C.red))),
          ],
          const SizedBox(height: S.x2),
          Center(
            child: Pressable(
              key: const ValueKey('gesture-failure-dismiss'),
              onTap: () => widget.store.dismiss(f.gestureId),
              semanticLabel: 'Dismiss',
              child: Text('Dismiss',
                  style: F.over.copyWith(
                      color: p.ink3, decoration: TextDecoration.underline)),
            ),
          ),
        ]),
      ),
    );
  }
}
