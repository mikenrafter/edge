/// APK1: the tappable health observation, in the SAME `home-why:` row list
/// as recovery/sleep/strain, first when present, within `card:rings`.
const apk1ObservationRow = 'home-why:observation';

/// APK1: the Settings > You & preferences control labelled Settings as tab.
/// Put this on its tap target, not on an inert caption.
const apk1SettingsToggle = 'apk1-settings-as-tab';

/// APK1: the fifth tab's semantics node: label Settings, selected when open,
/// containing a cog icon and the tap target. Absent when the pref is off.
const apk1SettingsTab = 'apk1-settings-tab';

/// APK1: the backed-up boolean UI preference. Absent means false.
const apk1SettingsPref = 'ui.settings_as_tab';

/// APK1: Sleep's visible selected-instant readout returned by _scrubCard.
/// Present during/after a scrub, absent before selection and after scrolling
/// from a chart without first selecting it.
const apk1SleepSelection = 'apk1-sleep-scrub-selection';
