import 'package:flutter/widgets.dart';

/// A real size change is controlled motion, including a read that finishes
/// before skeleton ink appears. Content always settles at its natural height.
class SettlingHeight extends StatelessWidget {
  const SettlingHeight({super.key, required this.child});
  final Widget child;
  static const duration = Duration(milliseconds: 200);
  @override
  Widget build(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
          context.dependOnInheritedWidgetOfExactType<_HeightOwner>() != null
      ? child
      : AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _HeightOwner(child: child),
        );
}

// Nested sections share their outer envelope; stacking size animations would
// make the parent chase a moving child and extend a 200 ms transition.
class _HeightOwner extends InheritedWidget {
  const _HeightOwner({required super.child});
  @override
  bool updateShouldNotify(_HeightOwner oldWidget) => false;
}
