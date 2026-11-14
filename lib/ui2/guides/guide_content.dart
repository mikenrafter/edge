// GUIDE CONTENT: caption-named content a step keeps in full colour (P7 offered
// controls via [GuideStep.alsoTap], P8 readable details via [GuideStep.alsoRead]).
// Resolved afresh from the live tree on every plan; nothing is stored.

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show Pressable;
import 'guide.dart';
import 'guide_target.dart';
import 'guide_text.dart';
import 'tree_geometry.dart';

/// Every pressable ROW built on the page (smaller than half the page, so a
/// page-wide tap area never counts): the list a caption offers ("tap one in the
/// list"), however many rows the page has built right now.
class PressableRows implements GuideContent {
  const PressableRows();

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) return const [];
    final found = <TargetFound>[];
    for (final e in onstageElements(root)) {
      final w = e.widget;
      final box = laidOutBox(e);
      if (w is! Pressable || w.onTap == null || box == null) continue;
      final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
      if (rect.isEmpty || box.size.height > rootBox.size.height / 2) continue;
      found.add(TargetFound(rect, renderObject: box));
    }
    return found;
  }
}

/// The controls or texts the screen prints under these [labels] (those that
/// resolve to exactly one place).
class LabelledContent implements GuideContent {
  final List<GuideText> labels;
  const LabelledContent(this.labels);

  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    for (final label in labels)
      if (GuideTarget.label(label).resolve(root, l) case final TargetFound found) found,
  ];
}
