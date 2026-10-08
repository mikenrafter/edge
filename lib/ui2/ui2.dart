// The one barrel for the one design system.
//
// The system this replaces shipped two — `lib/ui/design/` and `lib/ui/kit/` —
// re-exported from a single file, so a screen could pick either and no import
// told you which. There is exactly one here, and nothing outside lib/ui2
// should import its parts individually.

export 'app_shell.dart';
export 'as_of.dart';
export 'charts.dart';
export 'community_links.dart';
export 'grammar.dart';
export 'inline_loading.dart';
export 'last_result_cache.dart';
export 'live_hr.dart';
export 'metric_labels.dart';
export 'ecg_widgets.dart';
export 'gesture_failure_card.dart';
export 'haptic_score.dart';
export 'nudges.dart';
export 'paint_activity.dart';
export 'research_refs.dart';
export 'revision.dart';
export 'scroll_hint.dart';
export 'sync_control.dart';
export 'theme.dart';
export 'water_display.dart';
