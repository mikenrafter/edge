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
