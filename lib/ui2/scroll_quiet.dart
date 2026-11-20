// ScrollQuiet: one app-wide answer to "did a finger scroll something just now?"
//
// OWNER of the mutable state: [ScrollQuietListener] (one per app, high in the
// tree, above the Navigator). It records when the last USER-driven scroll
// moved; [QuietTap] (and so Pressable, SubTabs, BigButton, Surface/ActionCard)
// ignores a tap whose finger went DOWN within [ScrollQuiet.window] of that.
//
// CLAIM(scroll-tap-quiet) [owner m348]: the touch that stops a fling, or a
// thumb landing between two quick flicks, is not a choice of anything. 200 ms
// across the board, not just one page. Screen-reader activation never goes
// through the gate. Programmatic scrolls (animateTo, jumpTo, a row reveal, a
// pin glide) are not a finger and never start the quiet window.
// [test/ui2_scroll_quiet_test.dart], [test/pilot/day_tab_scroll_test.dart].
//
// No scope above (a widget test that pumps a bare screen) means no gating.
import 'package:clock/clock.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

abstract final class ScrollQuiet {
  /// A tap that starts sooner than this after a scroll moved is dropped.
  static const window = Duration(milliseconds: 200);

  /// True when a user scroll moved within [window] and a [ScrollQuietListener]
  /// is above [context].
  static bool recent(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ScrollQuietScope>()?.clock.recent ?? false;

  static bool _isUserScroll(ScrollNotification n) {
    // UserScrollNotification fires when the finger's direction changes, so it
    // also marks the finger leaving and a fling ending.
    if (n is UserScrollNotification) return true;
    final dragged = switch (n) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      OverscrollNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (dragged) return true;
    // A fling after the finger lifted: no drag details, but the position still
    // reports the finger's direction. A programmatic scroll reports idle.
    final ctx = n.context;
    if (ctx == null) return false;
    final position = Scrollable.maybeOf(ctx)?.position;
    return position != null && position.userScrollDirection != ScrollDirection.idle;
  }
}

class _QuietClock {
  DateTime? _last;
  void note() => _last = clock.now();
  bool get recent {
    final last = _last;
    if (last == null) return false;
    final age = clock.now().difference(last);
    return age < ScrollQuiet.window;
  }
}

class _ScrollQuietScope extends InheritedWidget {
  const _ScrollQuietScope({required this.clock, required super.child});
  final _QuietClock clock;
  @override
  bool updateShouldNotify(_ScrollQuietScope old) => false;
}

class ScrollQuietListener extends StatefulWidget {
  const ScrollQuietListener({super.key, required this.child});
  final Widget child;
  @override
  State<ScrollQuietListener> createState() => _ScrollQuietListenerState();
}

class _ScrollQuietListenerState extends State<ScrollQuietListener> {
  final _clock = _QuietClock();
  @override
  Widget build(BuildContext context) => _ScrollQuietScope(
        clock: _clock,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (ScrollQuiet._isUserScroll(n)) _clock.note();
            return false;
          },
          child: widget.child,
        ),
      );
}

/// A tap target that drops a tap whose finger landed within [ScrollQuiet.window]
/// of a scroll. [onTap] is also the semantics action and is NEVER gated.
class QuietTap extends StatefulWidget {
  const QuietTap({
    super.key,
    required this.child,
    this.onTap,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.behavior = HitTestBehavior.opaque,
  });
  final Widget child;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final GestureTapCancelCallback? onTapCancel;
  final HitTestBehavior behavior;
  @override
  State<QuietTap> createState() => _QuietTapState();
}

class _QuietTapState extends State<QuietTap> {
  bool _scrolledAtDown = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    return Semantics(
      onTap: onTap,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        // Sampled at pointer-down, before the scrollable's own hold stops the
        // fling (a child's Listener runs first): the touch that stops a fling
        // is the one to drop.
        onPointerDown: (_) => _scrolledAtDown = ScrollQuiet.recent(context),
        child: GestureDetector(
          behavior: widget.behavior,
          excludeFromSemantics: true,
          onTap: onTap == null ? null : () { if (!_scrolledAtDown) onTap(); },
          onTapDown: widget.onTapDown,
          onTapUp: widget.onTapUp,
          onTapCancel: widget.onTapCancel,
          child: widget.child,
        ),
      ),
    );
  }
}
