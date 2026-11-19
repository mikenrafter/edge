// Marks one element as "the same thing" on every screen it appears on.
import 'package:flutter/widgets.dart';

/// Keys [child] as `shared:<id>` so layout consistency checks can match it
/// across screens; use one id per shared thing, the same on every screen.
class SharedSlot extends StatelessWidget {
  final String id;
  final Widget child;
  const SharedSlot(this.id, {super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: ValueKey('shared:$id'), child: child);
}

/// `shared:content-top`: the point where a tab's first content begins, full
/// content width. Zero layout height (the 1 px child overflows its parent), so
/// adding it moves nothing; it exists so the start of the content can be
/// compared across tabs whatever that first content is.
class ContentTopMarker extends StatelessWidget {
  const ContentTopMarker({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 0,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: 1,
          maxHeight: 1,
          child: SharedSlot('content-top', child: SizedBox(height: 1)),
        ),
      );
}
