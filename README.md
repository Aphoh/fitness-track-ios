# FitnessTrack for iOS

A native SwiftUI port of [FitnessTrack](https://github.com/Gman0909/FitnessTrack) by
Giuliano Maciocci: a progressive-overload strength tracker using dynamic double
progression, adaptive tempo and deload suggestions.

Single-user and local-first. All data lives in one JSON file you control.

## Install on iPhone (free sideloading)

Each [release](https://github.com/Aphoh/fitness-track-ios/releases) has an unsigned
`FitnessTrack-ios-unsigned-v<version>.ipa`. A sideloader signs it with your own free Apple ID.
The app needs no entitlements, so nothing extra has to be provisioned.

1. Install one of these on your computer and follow its one-time setup:
   - [SideStore](https://sidestore.io) (recommended; refreshes on the phone itself).
   - [Sideloadly](https://sideloadly.io) (macOS/Windows; drag the `.ipa` in).
   - [AltStore](https://altstore.io) (needs AltServer running on your computer to refresh).
2. Install the `.ipa`. With SideStore or AltStore, you can instead add this source once and
   install and update from the **Browse** tab:
   `https://raw.githubusercontent.com/Aphoh/fitness-track-ios/main/altstore-source.json`
3. On first launch, trust your Apple ID under **Settings › General › VPN & Device
   Management**. On iOS 16 and later, turn on **Settings › Privacy & Security › Developer
   Mode** and restart when asked.

Notes:

- **7-day expiry.** Apps signed with a free Apple ID stop launching after 7 days. SideStore
  and AltStore re-sign them in the background; with Sideloadly, re-sideload or use its
  auto-refresh. Your data stays as long as you don't delete the app. A free Apple ID can
  have 3 sideloaded apps installed at once.
- **AltStore on OS 26.2.** AltStore currently fails to sign in on macOS/iOS 26.2
  ([altstoreio/AltStore#1695](https://github.com/altstoreio/AltStore/issues/1695)). Use
  SideStore or Sideloadly until it is fixed.
- Deleting the app deletes its Documents folder. To keep your data safe across reinstalls,
  move the data file to iCloud Drive (see below).

## Data file and iCloud

- By default the file is `FitnessTrack.json` in the app's Documents folder. It shows up
  in the Files app under **On My iPhone › FitnessTrack**.
- **Settings › Data file › Move data to a folder…** moves the file to any folder you
  pick, such as an iCloud Drive folder. **Open existing data file…** uses a file that
  already exists, for example one another device synced. The app saves the choice as a
  security-scoped bookmark and reopens that file on launch.
- Reads and writes go through `NSFileCoordinator`, and saves are atomic. An
  `NSFilePresenter` reloads the app when the file changes outside it, for example when
  iCloud Drive syncs an edit from another device.
- No iCloud entitlement or paid developer account is needed. The app runs with a free
  (personal) signing team, and iCloud Drive sync comes from the Files app.
- **Export backup / Restore** use FitnessTrack's web `fitnesstrack-export` v1 JSON
  format, so backups move both ways between this app and the web app.

## Building

Requires Xcode 16+ (iOS 17 deployment target, Swift 6).

```sh
brew install xcodegen      # only needed after editing project.yml
xcodegen generate
xcodebuild -project FitnessTrack.xcodeproj -scheme FitnessTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run on a device, open `FitnessTrack.xcodeproj`, choose your (free) team under
Signing & Capabilities, and change the bundle identifier if it is taken.

Launch with `-demoData` to load an in-memory, simulated training history (this is
never saved).

## Releasing

Push a version tag (or publish a GitHub release for one):

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The [Release workflow](.github/workflows/release.yml) builds the unsigned Release `.ipa`
with `tools/build-ipa.sh`, attaches it to the release (creating the release if needed), and
then commits the new version to `altstore-source.json` on `main` with
`tools/update-altstore-source.sh`. The tag sets the app version, and the commit count sets
the build number. Tags must be numeric (`v1.2.3`). To rebuild an existing tag, run the
workflow manually.

To build the `.ipa` locally: `tools/build-ipa.sh 1.0.0`.

## Layout

| Path | Contents |
|------|----------|
| `FitnessTrack/Core` | Pure ports of `shared/algorithm.js`, `deload.js`, `e1rm.js`, `recap.js`, `progressionHint.js`, `statsWeeks.js` |
| `FitnessTrack/Data` | Codable `AppState` (the file format) and the exercise-library seed |
| `FitnessTrack/Engine` | Session/progression engine (`recomputeExercise`, set-count versioning, slots), plans, calendar, stats, export/import |
| `FitnessTrack/Store` | State-file coordination, bookmark and presenter |
| `FitnessTrack/UI` | SwiftUI screens |
| `FitnessTrackTests` | Ported server tests, plus golden fixtures recorded from the JS (`tools/record-fixtures.mjs`) |

To regenerate the fixtures against a FitnessTrack checkout, run
`node tools/record-fixtures.mjs ../FitnessTrack`.

## License

MIT. See [LICENSE](LICENSE) for the original copyright notice and attribution.
