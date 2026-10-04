# Navigation depth

Settings is the landing screen: the Profile button on Home opens it directly,
and so does a tap on a battery notification (the `/profile` route). Every
setting is at most two pushes from Settings. A push is one screen opened on top
of another; each arrow below is one push. Paths start at Settings, so they are
one shorter than a count made from Home.

Row names are the labels on screen. "Before" is 8AE, when Settings sat one push
below a Profile home (paths start there). "After" is 8AF.7, with Profile home
gone.

| Screen | Before | After |
|---|---|---|
| Settings | Profile → Settings | Settings |
| Alerts and notifications | Profile → Settings → Alerts and notifications | Settings → Alerts and notifications |
| App notifications on the band | Profile → Settings → App notifications on the band | Settings → App notifications on the band |
| Gestures | Profile → Settings → Gestures | Settings → Gestures |
| Haptics | Profile → Settings → Haptics | Settings → Haptics |
| Alarm | Profile → Settings → Alarm | Settings → Alarm |
| Automation | Profile → Settings → Tasker and Shortcuts | Settings → Tasker and Shortcuts |
| Data | Profile → Settings → Export, backup, import | Settings → Export, backup, import |
| Expected sleep schedule | Profile → Settings → Expected sleep schedule | Settings → Expected sleep schedule |
| Device detail | Profile → My devices → Device detail | Settings → My devices → Device detail |
| Device lab | Profile → Settings → Device lab | Settings → Device lab |
| Edit profile | Profile → Settings → Edit profile | Settings → Edit profile |
| Live devices | Profile → Settings → Live devices | Settings → Live devices |
| AI coach | Profile → Settings → AI coach | Settings → AI coach |
| Language | Profile → Settings → Language | Settings → Language |
| Storage | Profile → Settings | Settings |

## What changed

- There is no Profile home. Its Quick access area is gone: Settings is the
  landing, and My devices stays in Settings > Hardware (called Band until 8AI),
  its one door. The Community links (GitHub, Reddit, Discord, Sponsor) are a
  Settings group, directly above Connections since 8AI.
  Nothing else lived only on the old screen: it never drew the profile name, and
  the Storage size was already in Settings > Data & privacy.
- Settings is grouped by task, in this order: You & preferences, Hardware,
  Alerts, Data & privacy, Community, Connections, About, and Developer
  (developer mode only). (8AI: You & preferences
  moved first, Community moved down to sit above Connections, and Band became
  Hardware. Hardware keeps the saved fold id `settings_band`, so nobody's
  remembered state is lost.)
- 8AI.2 moved Reset all data out of Settings (it was the last row) into Your data >
  Advanced, after Rebuild all history. One home; the confirmation is unchanged.
  Settings now ends with its last group.
- 8AI also moved "Look barcodes up online" from Data & privacy into Connections,
  and removed the Steps row from Settings: counting steps from the phone has one
  door, the phone's row in My devices.
- Alarm moved from Band to Alerts. It is the first row of the Alerts group on
  the Settings screen itself, not a row inside Alerts and notifications, so its
  depth did not change and it has one door.
- Settings keeps what 8AE moved into it: Live devices, Edit profile, AI coach,
  Language and Storage, and the whole "Your data" group. Each moved row has one
  door. Storage is a display row, not a screen.
- Device lab left the band's Device detail Tools. It opens from Settings >
  Developer (developer mode) and from Haptics > Calibration (developer mode).
  The tapClassifiers feature flag still gates its tap tools inside.
- "Band notifications" is now "App notifications on the band" (Android only).
  Its one door is Settings > Alerts; the second entrance in the Alerts and
  notifications screen is gone.
- Gestures no longer carries "Pause between double taps" or "Touch windows".
  Both stay in the Device lab.
- 8AK added "Gesture failures" as the last row of Settings > Hardware (after
  Haptics): one push from Settings, so depth 1, and it has no table row because
  it is new. It lists the last 20 gestures that failed to activate, dismissed
  ones marked, each with Save log file and Report. Home shows the newest
  undismissed failure as a card; dismissing it leaves it here.
- App notifications on the band: each channel (apps, alarms, calls) follows the
  quiet hours set in Alerts unless its "Override quiet hours" switch is on; its
  Starts and Ends rows show only then. In Alerts and notifications the "Band
  alerts" row is now "Band battery".
- Alarm: the Haptics group (one disabled Buzz pattern row) is gone. A row of
  weekday tabs (the app's sub-tab component) picks the day, then two accordions
  show that day: "Alarm and wake" (on or off, wake time, Natural Wake, Gradual
  Wake, and "Apply to full week") and "Timeline and status". The old notes about
  the band's own buzz and measured vocabulary are gone.
- Haptics is a row of sub-tabs (the app's sub-tab component), one push from
  Settings, so the depth is unchanged. Patterns (Your patterns, Presets),
  Alerts (the alert slots, then App notifications and automation), Activity
  (the workout slots), Cues (Gestures and Breathing) and Band (Safety, Test,
  and Calibration in developer mode). A tab with two or more groups folds them
  in accordions; Activity has one group and shows it as a plain card. The link
  to the screen where a section's slots are set is a text link at the bottom of
  its tab. The tab last used is remembered. The accordion's own hairline above
  each row is the only line; nothing is drawn beside a link.
- Every settings screen lists its settings as sections that start expanded
  (`SettingsAccordion`). A section can be folded; it keeps a one-line summary
  under its header while folded. Each section remembers whether it was open or
  folded: the state is stored per screen and section id (never the translated
  title) in the app preferences, so a section closed on the last visit is closed
  on the next.

## Intentional exceptions

- Expected sleep schedule is in Settings > You & preferences and also in
  Alarm > Wake. The alarm reads it, so the Wake group shows it in context. Both
  rows edit the same preference.

## Not in the table

- Pickers and sheets (buzz pattern, tap actions, time of day) open on top of the
  screen that owns them and are not counted. Language is listed because it is a
  settings row that moved, though it opens as a sheet.

## Health

Health has four sub-tabs, one time scope each: Last night, Today, Trends and
Labs. Paths start at the Health tab. A sub-tab is a chip, not a push, so the
first push is the first arrow. Deep links and notifications that land on Health
open on Last night.

Paths, as bullets (the table above is the settings table the guard test reads,
so this section does not use one):

- Last night, Readiness: Health → Last night → Readiness
- Last night, Sleep: Health → Last night → Sleep (opens that night)
- Last night, HRV, Resting heart rate, Respiratory rate, Overnight stress and
  Skin temperature: Health → Last night → the measure's detail
- Last night, HRV investigation: Health → Last night → HRV → Investigate
- Last night, Observations: Health → Last night → Observations (findings log)
- Last night, Daytime sleep: Health → Last night → Daytime sleep (Naps)
- Last night, Heart Screener (WHOOP MG only): Health → Last night → Heart
  Screener
- Today, Strain: Health → Today → Strain
- Today, Steps: Health → Today → Steps
- Today, Active minutes, Calories, Wear time and Heart rate: Health → Today →
  the measure's detail
- Trends, Body clock: Health → Trends → Body clock
- Trends, any measure with a history: Health → Trends → the measure's detail,
  opened on 30 days
- Trends, Investigate: Health → Trends → the measure's detail → Investigate
- Labs, Add a result: a sheet on Labs, not counted

The only second push listed here is Investigate, from a measure's own detail.

### What changed in 8AF

- The five sub-tabs (Overview, Explore, Trends, Vitals, Labs) became four. A
  sub-tab index remembered from the old order maps through
  `HealthScreen.tabFromLegacy`: Overview to Last night, Explore and Trends to
  Trends, Vitals to Today, Labs to Labs.
- Explore is gone as a tab. Trends lists every measure that has a history,
  grouped by family, and now includes Readiness and Stress. A family with no
  history folds into one card. Each row opens its detail on 30 days; every
  other way into a detail still opens on Today.
- Last night shows one night and no sparklines, and names the night by its date
  when it is not last night. Vitals is split: the heart rate range and wear time
  moved to Today, skin temperature and respiratory rate to Last night.
- The HRV deep-dive card on Vitals is gone. HRV has one detail, and
  Investigate is one tap further from its day card.
