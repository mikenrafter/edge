// SPOKEN ANNOUNCEMENTS: the one way the app speaks to a screen reader about
// something that changed where the user's focus is not.
//
// The rule (owner, 2026-11-15): only a result the USER started is announced
// when it lands (a sync they asked for, a reply they sent for, a pairing they
// began). A background refresh stays quiet. Announcements are polite: they
// wait for the reader to finish what it is saying.
//
//  * [announce]: say one sentence now, in the ambient text direction.
//  * [Announcer.of]: capture where to speak before awaiting work whose
//    widget may be gone when it ends (the Sync now link disappears while a
//    sync runs).
//  * [AnnounceOnChange]: say [AnnounceOnChange.message] each time it changes
//    after the first build (a pairing phase, the coach's reply count). Not on
//    the first build: opening a screen announces its title, not its state.
//  * [AnnounceLoadEnd]: a pending section that the user asked for says
//    [AnnounceLoadEnd.done] once it has loaded; a background reload of the
//    same section does not (the skeleton rollout reuses it).
//
// CLAIM(A11Y-ANNOUNCE): announcements are polite, RTL-correct and never sent
// for background work [ui2_a11y_announce_test].
import 'dart:ui' show FlutterView;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Where and how to speak, captured from a [BuildContext] that may not outlive
/// the work.
class Announcer {
  final FlutterView _view;
  final TextDirection _direction;
  const Announcer._(this._view, this._direction);

  factory Announcer.of(BuildContext c) =>
      Announcer._(View.of(c), Directionality.maybeOf(c) ?? TextDirection.ltr);

  /// Says [message] politely. Empty messages are dropped.
  void call(String message) {
    if (message.trim().isEmpty) return;
    SemanticsService.sendAnnouncement(_view, message, _direction,
        assertiveness: Assertiveness.polite);
  }
}

/// Says [message] politely, now.
void announce(BuildContext c, String message) => Announcer.of(c)(message);

/// Announces [message] each time it changes to a new non-empty value after the
/// first build. Draws nothing of its own.
class AnnounceOnChange extends StatefulWidget {
  final String? message;
  final Widget child;
  const AnnounceOnChange({super.key, required this.message, required this.child});

  @override
  State<AnnounceOnChange> createState() => _AnnounceOnChangeState();
}

class _AnnounceOnChangeState extends State<AnnounceOnChange> {
  @override
  void didUpdateWidget(AnnounceOnChange old) {
    super.didUpdateWidget(old);
    final m = widget.message;
    if (m != null && m.isNotEmpty && m != old.message) _speak(m);
  }

  void _speak(String m) {
    final say = Announcer.of(context);
    // After the frame, so the reader hears it once the new content is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => say(m));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wraps a section that loads. When [loading] goes from true to false and the
/// load was [userStarted], says [done]. A background reload stays quiet.
class AnnounceLoadEnd extends StatefulWidget {
  final bool loading;
  final bool userStarted;
  final String done;
  final Widget child;
  const AnnounceLoadEnd({
    super.key,
    required this.loading,
    required this.userStarted,
    required this.done,
    required this.child,
  });

  @override
  State<AnnounceLoadEnd> createState() => _AnnounceLoadEndState();
}

class _AnnounceLoadEndState extends State<AnnounceLoadEnd> {
  @override
  void didUpdateWidget(AnnounceLoadEnd old) {
    super.didUpdateWidget(old);
    if (old.loading && !widget.loading && old.userStarted) {
      final say = Announcer.of(context);
      final done = widget.done;
      WidgetsBinding.instance.addPostFrameCallback((_) => say(done));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
