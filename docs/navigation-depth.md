# Navigation depth

Every setting is at most two pushes from Profile home. A push is one screen
opened on top of another; each arrow below is one push. Paths start at Profile
home (the screen with Quick access), so they are one shorter than a count made
from Home.

Row names are the labels on screen. "Before" is the app as of 8F, "After" is 8A.

| Screen | Before | After |
|---|---|---|
| Settings | Profile → Settings | Profile → Settings |
| Notifications | Profile → Settings → Notifications | Profile → Settings → Notifications |
| Band notifications | Profile → Settings → Notifications → Band notifications | Profile → Settings → Band notifications |
| Gestures | Profile → Settings → Gestures | Profile → Settings → Gestures |
| Alarm | Profile → Settings → Alarm | Profile → Settings → Alarm |
| Automation | Profile → Settings → Automation | Profile → Settings → Automation |
| Data | Profile → Settings → Data | Profile → Settings → Data |
| Expected sleep schedule | Profile → Settings → Expected sleep schedule | Profile → Settings → Expected sleep schedule |
| Device detail | Profile → My devices → Device detail | Profile → My devices → Device detail |
| Edit profile | Profile → Edit profile | Profile → Edit profile |
| Live devices | Profile → (no entry point) → Live devices | Profile → Live devices |

## What changed

- Settings, "The band" group: Alarm, Band notifications (Android only, where the
  relay can run) and Gestures are direct rows. Gestures moved there from the
  Automation group, where it was labelled Double-tap. Notifications keeps its
  own Android Relay row as a second way in to Band notifications.
- Profile home, Quick access: a Live devices row. The screen had no way in
  before.
- Every settings screen lists its settings as sections that start expanded
  (`SettingsAccordion`). A section can be folded; it keeps a one-line summary
  under its header while folded.

## Not in the table

- Device lab is a tool, not a settings screen. It stays behind Device detail
  (Profile → My devices → Device detail → Device lab).
- Pickers and sheets (buzz pattern, tap actions, language, time of day) open on
  top of the screen that owns them and are not counted.
