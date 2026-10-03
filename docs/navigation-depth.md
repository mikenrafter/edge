# Navigation depth

Every setting is at most two pushes from Profile home. A push is one screen
opened on top of another; each arrow below is one push. Paths start at Profile
home (the screen with Quick access), so they are one shorter than a count made
from Home.

Row names are the labels on screen. "Before" is the app as of 8AD, "After" is
8AE.

| Screen | Before | After |
|---|---|---|
| Settings | Profile → More settings | Profile → Settings |
| Alerts and notifications | Profile → More settings → Manage notifications | Profile → Settings → Alerts and notifications |
| App notifications on the band | Profile → More settings → Band notifications | Profile → Settings → App notifications on the band |
| Gestures | Profile → More settings → Gestures | Profile → Settings → Gestures |
| Haptics | Profile → More settings → Haptics | Profile → Settings → Haptics |
| Alarm | Profile → More settings → Alarm | Profile → Settings → Alarm |
| Automation | Profile → More settings → Tasker and Shortcuts | Profile → Settings → Tasker and Shortcuts |
| Data | Profile → More settings → Export, backup, import | Profile → Settings → Export, backup, import |
| Expected sleep schedule | Profile → More settings → Expected sleep schedule | Profile → Settings → Expected sleep schedule |
| Device detail | Profile → My devices → Device detail | Profile → My devices → Device detail |
| Device lab | Profile → My devices → Device detail → Device lab | Profile → Settings → Device lab |
| Edit profile | Profile → Edit profile | Profile → Settings → Edit profile |
| Live devices | Profile → Live devices | Profile → Settings → Live devices |
| AI coach | Profile → AI coach | Profile → Settings → AI coach |
| Language | Profile → Language | Profile → Settings → Language |
| Storage | Profile | Profile → Settings |

## What changed

- Settings is regrouped by task, in this order: Band, Alerts, You &
  preferences, Data & privacy, Connections, About, and Developer (developer
  mode only). Reset all data stays last.
- Profile home keeps two Quick access rows, My devices and Settings (the old
  "More settings" row, renamed). Live devices, Edit profile, AI coach, Language
  and Storage, and the whole "Your data" group, moved into Settings. Each moved
  row has one door; My devices is the one deliberate pair (Profile Quick access
  and Settings > Band).
- Those moves put Edit profile, Live devices, AI coach and Language one push
  deeper than before (two pushes from Profile home, the limit). Storage is a
  display row, not a screen.
- Device lab left the band's Device detail Tools. It opens from Settings >
  Developer (developer mode) and from Haptics > Calibration (developer mode).
  The tapClassifiers feature flag still gates its tap tools inside.
- "Band notifications" is now "App notifications on the band" (Android only).
  Its one door is Settings > Alerts; the second entrance in the Alerts and
  notifications screen is gone.
- Gestures no longer carries "Pause between double taps" or "Touch windows".
  Both stay in the Device lab.
- App notifications on the band: each channel (apps, alarms, calls) follows the
  quiet hours set in Alerts unless its "Override quiet hours" switch is on; its
  Starts and Ends rows show only then. In Alerts and notifications the "Band
  alerts" row is now "Band battery".
- Alarm: the Haptics group (one disabled Buzz pattern row) is gone. Wake says
  once that the alarm uses the band's own buzz.
- Every settings screen lists its settings as sections that start expanded
  (`SettingsAccordion`). A section can be folded; it keeps a one-line summary
  under its header while folded.

## Intentional exceptions

- Expected sleep schedule is in Settings > You & preferences and also in
  Alarm > Wake. The alarm reads it, so the Wake group shows it in context. Both
  rows edit the same preference.

## Not in the table

- Pickers and sheets (buzz pattern, tap actions, time of day) open on top of the
  screen that owns them and are not counted. Language is listed because it is a
  settings row that moved, though it opens as a sheet.
