import 'dart:async' show FutureOr, unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'skeleton/pending_scope.dart';
import 'sync_control.dart' show showSyncDetails;
import 'theme.dart';

/// Wrap a tab's root scroll view, using [physics] on that view. Negative
/// scroll pixels move the entire list, and give the circle its position.
class PullToSync extends StatefulWidget {
  const PullToSync({super.key, required this.reload, required this.child});

  static const physics = BouncingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  final FutureOr<void> Function() reload;
  final Widget child;

  @override
  State<PullToSync> createState() => _PullToSyncState();
}

class _PullToSyncState extends State<PullToSync> {
  static const _trigger = 72.0;
  static const _diameter = 36.0;

  double _distance = 0;
  double? _releasedAt;
  bool _dragging = false;
  bool _armed = false;

  bool _scroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;

    if (n is ScrollUpdateNotification) {
      final distance = math.max(0.0, n.metrics.minScrollExtent - n.metrics.pixels);
      if (n.dragDetails != null) {
        final armed = distance >= _trigger;
        if (_armed != armed && (_dragging || armed)) {
          unawaited(HapticFeedback.selectionClick());
        }
        if (_distance != distance || _releasedAt != null || _armed != armed) {
          setState(() {
            _distance = distance;
            _armed = armed;
            _releasedAt = null;
          });
        }
        _dragging = distance > 0;
      } else {
        _release();
        if (_distance != 0) setState(() => _distance = distance);
      }
    } else if (n is ScrollEndNotification) {
      _release();
      if (_distance != 0 || _releasedAt != null) {
        setState(() {
          _distance = 0;
          _releasedAt = null;
        });
      }
    }
    return false;
  }

  void _release() {
    if (!_dragging) return;
    _dragging = false;
    if (!_armed) return;
    setState(() {
      _armed = false;
      _releasedAt = _distance;
    });
    final app = context.read<AppState?>();
    final wasSyncing = app != null && (app.syncPresentation.busy || app.offloadActive);
    // Scroll notifications can arrive during layout. Let the viewport finish
    // the frame before opening a route or publishing sync state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_sync(app, wasSyncing: wasSyncing));
    });
  }

  Future<void> _sync(AppState? app, {required bool wasSyncing}) async {
    if (app != null) {
      if (wasSyncing || app.syncPresentation.busy || app.offloadActive) {
        await showSyncDetails(context, app);
        return;
      }
      await app.refreshData();
    }
    if (mounted) await PendingUserAction.run(widget.reload);
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final progress = (_distance / _trigger).clamp(0.0, 1.0);
    final releasedAt = _releasedAt;
    final turns = releasedAt == null
        ? progress
        : 1 + (1 - _distance / releasedAt).clamp(0.0, 1.0);
    return Listener(
      onPointerCancel: (_) {
        _dragging = false;
        if (_armed) setState(() => _armed = false);
      },
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _scroll,
            child: widget.child,
          ),
          if (_distance > 0)
            Positioned(
              top: math.min(-16 + .72 * _distance, _distance - _diameter - 2),
              child: IgnorePointer(
                child: Opacity(
                  opacity: progress,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.card2,
                      shape: BoxShape.circle,
                      boxShadow: p.el(2),
                    ),
                    child: SizedBox.square(
                      dimension: _diameter,
                      child: Transform.rotate(
                        angle: Motion.enabled(context) ? turns * 2 * math.pi : 0,
                        child: Icon(LucideIcons.rotateCcw, size: 22,
                          color: _armed || releasedAt != null ? p.on(C.green) : p.ink2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
