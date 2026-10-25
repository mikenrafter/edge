/// APK2 key contract. Production uses ValueKey<String> with these values.
/// Item identity is `activity:<ActivitySuggestion.id>` for a detection and
/// `moment:<YYYY-MM-DD> <HH:mm>` for a marked moment, pending or answered.
/// Prefix constants are followed by that identity, without escaping it.
const apk2Tray = 'apk2-review-tray';

/// One card per queued item on the CURRENT tray page, including staged items.
const apk2TrayItemPrefix = 'apk2-review-item:';

/// Tray Keep button. Selected semantics mean a staged Keep; tap again undoes.
const apk2KeepPrefix = 'apk2-review-keep:';

/// Tray Discard button. Selected semantics mean a staged Discard; tap undoes.
const apk2DiscardPrefix = 'apk2-review-discard:';

/// Save button, with an enabled/disabled button semantics node on this widget.
const apk2Save = 'apk2-review-save';

/// Previous-page button, disabled on page one, with button semantics.
const apk2Previous = 'apk2-review-previous';

/// Next-page button, disabled on the last page, with button semantics.
const apk2Next = 'apk2-review-next';

/// Page indicator. English text and its single spoken status are `1 of 2` etc.
const apk2Page = 'apk2-review-page';

/// Visible, singly spoken `Nothing to review` status inside the reserved tray.
const apk2Empty = 'apk2-review-empty';

/// Visible, singly spoken error when Save fails; staged choices remain editable.
const apk2SaveError = 'apk2-review-save-error';

/// Visible, singly spoken error when the queue cannot load. Never an empty state.
const apk2LoadError = 'apk2-review-load-error';

/// Retry button for a failed queue read.
const apk2Retry = 'apk2-review-retry';

/// Confirmation dialog shown when leaving with unsaved decisions.
const apk2LeaveDialog = 'apk2-review-leave-dialog';

/// Cancel leaving, keeping the current page and every staged choice.
const apk2Stay = 'apk2-review-stay';

/// Confirm leaving, throwing away staged decisions without changing the store.
const apk2Leave = 'apk2-review-leave';

/// The pinned chart's render box, excluding the independently scrolling list.
const apk2Chart = 'apk2-day-chart';

/// The bounded list viewport, containing its vertical Scrollable.
const apk2List = 'apk2-day-list';

/// A list row keyed by the same item identity used in the tray and chart.
const apk2RowPrefix = 'apk2-day-row:';

/// A tappable chart icon/marker for an item, keyed by that item's identity.
const apk2MarkerPrefix = 'apk2-day-marker:';

/// Present immediately after a marker tap while that row is visibly highlighted;
/// clears within five seconds without another interaction.
const apk2HighlightPrefix = 'apk2-day-highlight:';

/// List-row Keep control. Present but disabled for items not needing review.
const apk2RowKeepPrefix = 'apk2-day-keep:';

/// List-row Discard control. Present but disabled for items not needing review.
const apk2RowDiscardPrefix = 'apk2-day-discard:';

/// List-row explanation. English visible/spoken text is `Already reviewed` for
/// answered moments. It is spoken once for the row, not once per disabled button.
const apk2DisabledReasonPrefix = 'apk2-day-review-reason:';
