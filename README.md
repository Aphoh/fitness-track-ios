# FitnessTrack for iOS

A native SwiftUI port of [FitnessTrack](https://github.com/Gman0909/FitnessTrack) by
Giuliano Maciocci: a progressive-overload strength tracker using dynamic double
progression, adaptive tempo and deload suggestions.

Single-user and local-first. All data lives in one JSON file you control.

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
