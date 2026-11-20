# App updates

App updates is an Android, opt-in check of public releases in `OpenStrap/edge`
and `mikenrafter/edge`. The app opens a release page after a tap. It has no APK
fetch, installer, install permission, compulsory update or build-mode switch.

Settings shows the last result for each source independently. Official releases
use semantic version order; official prereleases require a separate choice.
Fork prereleases are included, ordered by their manifest's `versionCode`.
An official release shown in the fork is a release of a separate application;
the fork's build counter is never compared with an official counter. On a fork
install, official releases at or below the fork's own semantic version are
informational. Only a higher official version drives an announcement, explicitly
labelled as a separate app whose data stays in this app.

`UpdateCoordinator` owns checks and observable state (discovery wire code is `update_http.dart`, selection is pure in `update_selection.dart`). `UpdateStore` owns consent,
cache, deadlines, generation-checked leases and permanent notification claims in
`release-checks-v1.db`, outside the health database and exports. Android stores it
in `noBackupFilesDir`. Previous companion-update preferences grant no consent.

Automatic checks use a daily WorkManager task constrained to unmetered networks.
The worker and foreground path also check the active network's validated and
unmetered capabilities. A persisted deadline and lease coordinate both paths.
Check now is a separate one-time request, with a metered-network warning and a
60-second minimum interval. Disabling checks cancels the task, invalidates an
active generation and clears results. A response from that generation cannot
restore cache or authorize another metadata request. Each alert claim also carries
its consent generation, checked after the final policy await at every delivery
destination. Turning consent off and back on cannot revive an older attempt.

Requests contain only static GitHub headers and an optional ETag. No health,
installed version, ABI, package, identifier, credentials or telemetry is sent.
GitHub sees the IP address, request time and resource. Release listings use
`GET /repos/{source}/releases?per_page=100`, with at most three pages and 2 MiB per
response. Fork manifests use the API's numeric asset endpoint, at most eight
new manifests and 256 KiB each. Validated manifest fields are cached by release,
asset ID and API modification time; a large cold catalog makes progress across
checks. A bounded selection summary preserves the maximum and blockers after
manifest eviction. Pagination continues across batches, rechecking page 1 and
every later page before publishing a result. A changed page restarts discovery.
Continuation is capped at 64 pages, 1024 relevant releases and 128 KiB per source;
an exceeded bound stays incomplete. Cache entries are revalidated against the current asset list before use. Each request has a 12-second timeout. List redirects
are refused. Manifest redirects are restricted to HTTPS
`release-assets.githubusercontent.com`, at most three hops; their URLs are not
cached. No APK URL is ever requested. A bound that prevents a complete result
produces an error, never an up-to-date claim. Rate limits persist a per-source
retry deadline that Check now also respects. An ordinary forbidden response
is a network error, not a rate limit. Server retry dates are capped at seven
days; Check now can retry once that deadline passes.

Release bodies and `html_url` are ignored. Navigation is reconstructed from a
supported tag and one of the two fixed repositories. Notification taps pass
through the same release-page validator. Update announcements use the existing
`NotificationCenter.emit` path through the central alert policy: quiet hours and
sleep HOLD the alert (its claim stays reserved and is reused when the policy
releases it), phone by default, with the global fallback destination. The claim
ledger and OS id come from this store. The background worker scopes a DB-free
sleep source that holds unknown sleep eligibility for a foreground recovery
pass. It never opens the health database. After the atomic release claim,
permission is checked without prompting;
only the Settings permission button may prompt. A crash after a claim can lose
one alert, but cannot repeat it. Claims and OS notification IDs stay in this update database. A held or permission-deferred alert is re-offered from fresh cache on resume and
on the shared recovery pass, without another request. Claims are not dated and never expire.

## Fork metadata contract

The release script should publish one `edge-release.json` alongside the fixed
APK names. This pilot reads the following fields (other inspection fields from
the release design may also be included):

```json
{
  "formatVersion": 1,
  "repository": "mikenrafter/edge",
  "tag": "next-2026.11.15",
  "sourceSha": "0123456789abcdef0123456789abcdef01234567",
  "versionCode": 79,
  "artifacts": [
    {
      "name": "openstrap-edge-next-2026.11.15-dev-profile-arm64-v8a.apk",
      "mode": "profile",
      "package": "wtf.openstrap.openstrap_edge.dev",
      "abis": ["arm64-v8a"]
    }
  ]
}
```

`versionCode` is the shared increasing fork counter. Each artifact names an
existing API asset exactly once. Mode is `profile` or `release`. ABI names are
`arm64-v8a`, `armeabi-v7a`, and `x86_64`. Portable names omit the ABI suffix and
list the ABIs they contain. Package is always `wtf.openstrap.openstrap_edge.dev`.
Names are `openstrap-edge-{tag}-dev-{mode}[-{abi}].apk`. Only the current compiled
mode is matched; there is no mode-switch control. Unknown formats, duplicate
entries and inconsistent names or package identities are refused. Older releases
with missing or malformed manifests do not hide a newer valid candidate. An
unrecognized release with a newer date tag blocks fallback to an older one.

Official names are `openstrap-edge-{tag}[-{abi}].apk`, release mode only.
Architecture preference follows Android's ordered supported ABI list, then a
portable asset. This identifies release metadata, not verified APK bytes: the
app neither downloads an APK nor claims its signer or binary compatibility.

Focused coverage lives in `test/updates/`. Android scheduling on restricted OEM
builds and end-to-end OS notification taps still need a device trial before
public release.

## First APK hardening gate

Before distributing the first APK containing this checker, run this on its build
host with the Android SDK available. Supply that APK's exact source head, variant
and Gradle merged-manifest directory:

```sh
tool/check_update_apk.sh --apk /path/to/edge.apk
# optional: --merged-manifest DIR (default build/app/intermediates/merged_manifests/*elease*),
#           --head FULL_COMMIT_SHA (default HEAD), --variant NAME (default release), --output DIR
```

The script requires nonempty inputs, dumps the packaged manifest with `aapt2`
(or `aapt`), scans it and every merged manifest with `tool/scan_manifest.dart`
(the one install-capability scanner), then runs `test/guards` against the same
files (the `EDGE_MERGED_MANIFEST` and `EDGE_APK_MANIFEST_DUMP` groups). Evidence
contains the head, variant, input hashes and logs. `PASS` is written only after
every step succeeds. Missing inputs, a failed dump or a banned installer
capability fail the gate. This command inspects an existing APK and never installs
it. `AAPT2`, `AAPT`, `DART` and `FLUTTER` can name the build host's tools;
otherwise PATH, then `$ANDROID_HOME/build-tools`, is searched.

## Release build provenance

Release builds go through `tool/build_release.sh` (CI and `make build`). It sets
`OPENSTRAP_SOURCE_SHA` (default: `git rev-parse HEAD`, which it must equal) and
`OPENSTRAP_SOURCE_TAG` (default: the tag on HEAD) as `--dart-define`s, which
`lib/data/official_export/mapper.dart` exports, and fails before building when
either is missing, `unknown`, or malformed (`tool/check_release_provenance.sh`).
Example: `OPENSTRAP_SOURCE_TAG=pilot-1 tool/build_release.sh apk --target-platform android-arm64`.
