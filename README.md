# GravelFit

A native macOS 15+ bike fitting application written in Swift 6 and SwiftUI. It uses AVFoundation for cameras and recordings, Apple Vision for local body-pose estimation, Swift Charts for measurements, and JSON for local sessions. There are no package dependencies, accounts, servers, web views, analytics, or network entitlements.

## Installation

### Requirements

- **To run:** a Mac with macOS 15 or later. The project builds for Apple Silicon and Intel.
- **To build from source:** the full [Xcode application](https://developer.apple.com/xcode/) with Swift 6 support. This project is verified with Xcode 27.0 and Swift 6.4. Check [Apple's Xcode system requirements](https://developer.apple.com/xcode/system-requirements) when installing Xcode on your Mac.
- **For live fitting:** a built-in webcam, external camera or compatible iPhone using Continuity Camera. You can also import a recorded video.

The project includes its Xcode project and shared scheme. It requires no package installation, project generator or Python at runtime. Bike profiles and bike dimensions are optional.

### Run from Xcode

1. Download or copy the source folder containing `GravelFit.xcodeproj` to your Mac. If supplied as an archive, extract it first.
2. Install Xcode, launch it once, and let it complete its initial setup.
3. Open `GravelFit.xcodeproj` in Xcode.
4. Select the **GravelFit** scheme and **My Mac** as the destination.
5. Choose **Product → Run** or press **⌘R**. Xcode builds and launches GravelFit.

### Build and install in Applications

Open Terminal in the project folder and build a Release app:

```sh
xcodebuild -project GravelFit.xcodeproj -scheme GravelFit \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build-release build

open build-release/Build/Products/Release
```

In the Finder window that opens, drag **GravelFit.app** into **Applications**. You can use `~/Applications` for an installation in your own account. Then launch GravelFit from the installed location. If you already have a built `GravelFit.app`, you can copy it directly; Xcode is needed only for building from source.

Local builds use ad hoc signing. If a downloaded build produces a developer-verification prompt and you trust its source, follow [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445): try opening it, then use **System Settings → Privacy & Security → Open Anyway** and confirm **Open**.

### Camera permission and iPhone setup

1. In GravelFit, open **Live Bike Fit** or **Calibrate**, select a camera, and choose **Connect**.
2. Allow camera access when macOS asks. If access was denied, enable GravelFit under **System Settings → Privacy & Security → Camera**, then reopen the app and reconnect.
3. For an iPhone, follow [Apple's Continuity Camera setup](https://support.apple.com/en-us/102546). It requires an iPhone XR or later with iOS 16 or later, the same Apple Account with two-factor authentication, and Continuity Camera enabled. Keep the phone locked and near the Mac; use Wi-Fi/Bluetooth or a USB connection that trusts the Mac.
4. Select the iPhone in GravelFit's camera picker. Mount it vertically for the app's portrait recording mode, then complete calibration. No iPhone companion app is needed.

Microphone permission is not required. See **First fitting** below for camera positioning and calibration.

### Update or remove the app

To update, quit GravelFit, build the new Release version, and replace the installed `GravelFit.app` in Finder. Relaunch the installed copy. Profiles, sessions and recordings live in app storage separately from the app bundle; replacing the bundle keeps that data.

To uninstall, quit GravelFit and move the app to Trash. If you also want to remove fitting data, use **Settings → Delete all saved data…** before removing the app.

## Development builds and tests

Local command-line build and tests:

```sh
xcodebuild -project GravelFit.xcodeproj -scheme GravelFit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build

xcodebuild -project GravelFit.xcodeproj -scheme GravelFit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build test

open build/Build/Products/Debug/GravelFit.app
```

For signing with your own identity, select a development team in **Signing & Capabilities** and set **Code Signing Identity** to **Apple Development**, or pass `DEVELOPMENT_TEAM=YOURTEAM CODE_SIGN_IDENTITY='Apple Development'` to `xcodebuild`. The bundle identifier is `com.gravelfit.app`. Camera, sandbox, and user-selected file access entitlements are included. No microphone permission is requested or audio input attached.

If Terminal reports that `xcodebuild` needs Xcode, select the full Xcode installation and complete its setup, then retry the build:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

In an execution environment that prevents Xcode's nested compiler-plugin sandbox from starting, the Apple-provided Swift macros can be compiled using this additional **command-line-only** option:

```sh
xcodebuild -project GravelFit.xcodeproj -scheme GravelFit \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' \
  build-for-testing

xcrun xctest build/Build/Products/Debug/GravelFitTests.xctest
```

This compiler option does not change the app's sandbox or entitlements and is not saved in the project. The standalone XCTest target compiles the same production core and persistence/video services without launching the GUI or requesting a camera.

## First fitting

1. Secure the bike on an indoor trainer. Mount the camera roughly at hip height, perpendicular to the bicycle and far enough away to minimize perspective distortion.
2. On the first-run welcome screen, choose **Set up my camera**, or open **Calibrate** from the toolbar. Select a discovered camera and choose **Connect**. macOS asks for camera access at this point.
3. Check that the visible-side shoulder, elbow, wrist, hip, knee, and ankle remain in frame throughout pedaling. Keep other people out of the image and use even lighting.
4. Confirm the floor reference. Floor slope is in degrees in the unmirrored image, positive when rising to the right. Select your anatomical left/right side and hands on the hoods, drops, or tops.
5. Pedal for at least ten seconds. Calibration requires at least 80% reliable frames and three detected knee-flexion strokes. Continue to live analysis.
6. In **Live Bike Fit**, leave **Bike → No bike profile** selected to fit directly from camera measurements, or optionally select a measured bike profile. Inspect live measurements and use the guided eight-step assistant. Begin with a reliable eight-second measurement. After a physical change, enter its measured signed amount, confirm it, and collect a fresh measurement before making another change.
7. Choose **Record session** to save a movie and measurements. **Save metrics** saves the current rolling thirty-second analysis without video. A **New fit** starts a fresh assistant workflow; save your existing observations and adjustments first.

Leaving **Live Bike Fit**, opening the separate Settings window, or closing the main window stops the camera and cancels an in-progress measurement capture. If a movie is recording, recording stops and the session is finalized. Returning to Live Bike Fit leaves the camera off until you choose **Connect**. Closing calibration also stops the camera when Live Bike Fit is not the current workspace.

Continuity Camera uses standard AVFoundation discovery, including `.continuityCamera`; the app does not identify an iPhone by its display name. Configure the iPhone and Mac for Apple's Continuity Camera, mount and lock the phone, then select it from the discovered devices. A disconnected selected device is rediscovered and automatically reconnected when it returns. Camera denial links to System Settings; unavailable cameras, interruptions, partial poses, multiple people, and Vision errors produce explicit status messages.

iPhone connections use portrait orientation by default for preview, pose analysis and recording. Mount the phone vertically; **Settings → Video orientation → Portrait upside down** handles an inverted mount. Other camera types retain their chosen orientation. Recording uses [AVFoundation's video rotation API](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle), which stores movie orientation in its track transform; frame inspection and offline analysis apply that transform.

Apple's setup requirements and discovery details are documented in [Continuity Camera support](https://support.apple.com/en-us/102546) and the [Continuity Camera device API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/continuitycamera).

## Measurements and interpretation

All joint angles are calculated in image **pixel space**, after converting Vision's normalized coordinates. This avoids distorting angles on non-square images. Preview and recording orientation are configured through AVFoundation connections. Video uses aspect-fit letterboxing; overlays use the same aspect-fit geometry and a separate display-only mirror transform. Left/right labels always refer to the rider's anatomical side.

| Measurement | Definition and interpretation |
| --- | --- |
| Knee flexion | `180° − interiorAngle(hip, knee, ankle)`. Live flexion depends on pedal phase. |
| Maximum dynamic extension | Median minimum knee flexion across at least three recent detected strokes. Working reference defaults to 30–40°. Between-stroke standard deviation describes repeatability. |
| Knee at bottom dead center | Available only from manually identified recorded frames. Separate working reference defaults to 33–43°. |
| Hip angle | Interior shoulder–hip–knee angle. This is a video-derived torso/thigh angle, **not anatomical hip flexion**. There is no universal ideal. |
| Hip near top dead center | Calculated on a manually identified TDC frame. No universal target is applied. |
| Torso | Acute hip-to-shoulder angle relative to the configured ground reference, independent of which horizontal direction the rider faces. Working endurance-gravel range defaults to 40–55°. |
| Elbow | Interior shoulder–elbow–wrist angle. Repeated near-straight elbows prompt a comfort/reach check, not a universal angle prescription. |
| Vertical hip motion | Five-second 5th–95th percentile vertical excursion, normalized to visible thigh + lower-leg length. Requires at least two seconds of reliable data. Values above 5% are an observation flag to repeat, not a validated saddle-instability threshold. |
| Confidence | Vision detection confidence. It is **not** a calibrated estimate of angular accuracy. |

The temporal filter holds missing joints for up to 0.2 seconds as dashed, faded overlay points. Held points never produce numerical measurements. Multiple people invalidate tracking. Missing or low-confidence required joints produce unavailable readings. Recommendations additionally require sustained visible-side tracking, calibration, and repeatable stroke extrema. Current measurements disappear when camera frames become stale; historical statistics remain clearly historical.

Knee-flexion cycles estimate repeated strokes from prominence and plausible cycle duration. They do not locate the crank. Maximum leg extension is never automatically labeled BDC or TDC. Side-view hip motion cannot measure lateral pelvic rocking: use a rear view for that observation. Foot/cleat rotation and frontal knee tracking also require direct inspection or another view.

## Sessions, inspection, comparison and exports

- **Recorded Sessions** provides video playback, a scrubber, nominal frame-rate stepping and decoded timestamps. Choose **Inspect paused frame**, confirm that you can identify the crank position, then mark TDC/BDC. The frame appears before its pose analysis finishes. Manual labels remain available if Vision fails or detects no cyclist; uncertain joint angles stay unavailable. Inspection supports cancellation, rejects stale results and reports a timeout after ten seconds instead of leaving the spinner running. Each label uses the actual decoded frame timestamp.
- **Trim & analyze video…** opens a preview with start/end seconds, range sliders and **Set from playhead** controls. Analysis begins after confirmation, on a new trimmed movie and session. The original recording and session remain intact. Existing annotations inside the selected range are carried into the new session with timestamps starting at zero; labels outside the cut are excluded.
- **Import video…** opens the same trim preview before copying or analyzing the video. Choose a range or **Use full video**, then **Trim & analyze**. Track orientation is applied before Vision processing. Processing can be canceled; incomplete outputs are removed. Unsupported or corrupt videos produce an error instead of a fabricated session. Trimming uses the [asynchronous AVFoundation export API](https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:)) with passthrough media export.
- **Before / After** selects two distinct sessions, drives both videos from shared controls, schedules playback against the same host clock, corrects drift, and supports a phase-alignment offset. It compares means, minima, maxima, vertical hip movement, graphs and logged millimeter/degree adjustments. Playback is limited to the overlapping time interval.
- Set a session as your **baseline**. Export measurements as CSV, the complete session as JSON, or a local plain-text summary with adjustments, setup snapshot, annotations, observations and uncertainty notes.
- Bike profiles are optional and support gravel, road and endurance bikes, all requested setup dimensions, and cleat/rider notes. When a profile is selected, each session stores its bike ID and setup snapshot so later profile edits do not rewrite its historical setup. With **No bike profile**, live measurements, the guided assistant, recordings, saved metrics and imported videos work without bike dimensions; saved sessions omit the bike ID and setup snapshot.

In **Bike Profiles**, select a bike and edit its name, type, measurements or notes, then choose **Save changes**. **Revert changes** discards the edits. Edits stay available while switching between profiles in that workspace. **Delete bike…** is available in the editor and the profile's context menu; confirm to remove the profile while keeping its saved sessions and setup snapshots. Deleting the active bike returns fitting to **No bike profile**. You can delete every profile and continue fitting. Finish recording/importing first, and start a new fit before deleting the active bike if measurements or adjustments are in progress.

Saved chart/CSV timelines are sampled at approximately 2 Hz; analysis and stroke detection run at the selected adaptive cadence. Session min/max/means are accumulated at the full analysis rate, independently of the chart sampling. Measurements-only saves contain the full thirty-second rolling history. Live-recorded timelines begin at the first analyzed recording frame and can have a small startup offset relative to the movie. Manual annotations are always remeasured on the actual video frame; use the comparison offset to align video phases.

Graphs break at unavailable readings and reduce long timelines to bounded drawing work while retaining bucket extrema. A new app launch requires fresh calibration because saved settings do not establish the current physical camera alignment.

## Storage and privacy

GravelFit requests camera access only on Connect. Movie recording starts only after Record. Previewing, calibrating and measuring alone do not write video. Imported videos are explicitly selected by the user. All analysis stays on the Mac.

The application uses `Application Support/GravelFit` within its macOS app container. The exact path is visible under **Settings → Local storage & privacy**. The directory contains:

- `configuration.json`: bikes and fitting settings;
- `session-UUID.json`: measurements, full-rate statistics, strokes, bike snapshot, confirmed changes and crank annotations;
- `video-UUID.mov` or the imported movie extension;
- `journal-UUID.jsonl`: bounded disk-backed measurement writes during recording, removed after successful finalization and recovered on restart after an interruption.

AVFoundation writes movies directly to disk. The thirty-second live history and trails are bounded, late capture frames are dropped, Vision runs one request at a time, and main-thread pose delivery buffers only the newest pose. Journal writes have a 32-entry limit and stop the recording on disk failure/queue saturation. Quitting waits for recording finalization or import cancellation. No camera frame is uploaded and the sandbox has no network entitlement.

Delete an individual session and its video in Recorded Sessions. **Delete all saved data** removes videos, sessions, journals, profiles, settings and the first-run preference, then resets fitting settings. A fresh installation starts without bike profiles.

## Architecture

| Component | Responsibility |
| --- | --- |
| `CameraManager` / `CapturePipeline` | Main-actor UI state; serial capture-session configuration, lifecycle notifications, 1080p preference with fallback, supported 30–60 FPS preference, rotation and movie recording. |
| `PoseDetectionService` | Serial, bounded Vision requests on captured pixel buffers with adaptive analysis frequency. |
| `JointTrackingEngine` | Confidence gating, temporal smoothing, short visual-only missing-joint grace. |
| `BiomechanicsEngine` / `BikeFitAnalysisEngine` | Testable geometry, rolling statistics and side-view hip excursion. |
| `PedalCycleAnalyzer` | Repeated knee-flexion extrema and consistency, independent of crank phase. |
| `CalibrationManager` | Eight-step setup and sustained tracking quality gate. |
| `BikeFitRecommendationEngine` | Separate conservative, uncertainty-aware guidance. |
| `SessionRecorder` / `SessionRepository` | Bounded measurement journal, atomic local JSON persistence, recovery, profiles, deletion and exports. |
| `OfflineAnalyzer` | Actor-isolated video decoding, oriented local Vision analysis and exact-frame inspection. |
| `VideoOverlayRenderer` | Reusable aspect-fit and mirrored coordinate mapping. |
| `LiveFitViewModel` | Main-actor orchestration, recording/import lifecycle and adjustment captures. |

UI state is main-actor isolated. Capture-session mutations use one serial dispatch queue; Vision uses a separate serial delegate queue. `@unchecked Sendable` is restricted to queue-confined AVFoundation/file wrappers; value types crossing threads are Sendable. The app uses native navigation, resizable split panels, system light/dark colors, SF Symbols, accessible controls, keyboard shortcuts, and a separate full-screen-capable analysis window.

Shortcuts: **⌘⇧R** record/stop, **⌘S** save measurements, **⌘⇧I** import video, **⌘,** settings.

Project regeneration is optional after adding source files: `python3 scripts/generate-project.py`. Python is used only for project/test-fixture generation; it is not included in the app or used for analysis. The icon is a Core Graphics drawing; regenerate with `xcrun swift -module-cache-path build/ModuleCache.noindex scripts/generate-icon.swift "$PWD"`.

## Verification and practical limitations

Automated tests cover angle math, knee conversion, floor-relative torso angle, image aspect ratio, mirroring, smoothing, confidence gating, missing/multiple-person poses, pedal extrema and gaps, reference ranges, bounded history, full-rate aggregates, recommendations, persistence/export/deletion, path containment and interrupted-recording recovery. The video integration test uses a checked-in small uncompressed movie and exercises offline Vision plus exact-frame inspection. It skips only when the runner reports the specific denied IOSurface/CoreVideo transport error (`-6662`). Metadata decoding and unsupported-video handling are tested separately.

In this restricted workspace, Xcode builds can run and XCTest can run directly. The normal `xcodebuild test` launcher, GUI launch, IOSurface transport, and hardware encoders are restricted. See `VALIDATION.md` for actual build/test results and the local hardware checks still needed. **Continuity Camera functionality has not been verified with an actual iPhone**, and GUI/hardware performance should be checked locally before relying on the app for a fitting.

2D Vision pose estimation depends on lens perspective, camera alignment, clothing, occlusion, lighting and the rider's movement. The app does not calibrate physical length from an image, infer a true 3D hip angle, automatically identify the crank, diagnose discomfort, or establish medical outcomes. Its conservative fitting references and suggestions are starting observations to validate through repeated captures and comfort checks.
