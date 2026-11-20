// Loading is a structural placeholder, not a spinner (fa1e52e04 and d3c53c24c,
// 2026-11-14: "Replace pilot loading spinners with stable skeleton layouts",
// "Make loading placeholders structural across the app"; the owner's loading-feel
// directive of 2026-11-20 builds on it). Tests that used to look for a
// ProgressIndicator look for what stands in for it.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';

/// A section whose read is still pending (an InlineLoading draws one too).
final Finder pendingSection = find.byWidgetPredicate(
    (w) => w is PendingContent && w.pending,
    description: 'a pending section');

/// The small pending mark that replaced a spinner beside a status line.
final Finder pendingMark = find.byType(PendingMark);

/// Whatever shows "still loading": a pending section or mark, or (older code)
/// a ProgressIndicator.
final Finder anyLoadingIndicator = find.byWidgetPredicate(
    (w) => w is PendingMark || (w is PendingContent && w.pending),
    description: 'a pending placeholder');
