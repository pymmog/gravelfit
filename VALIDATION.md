# Validation

The application is implemented; hardware-dependent functionality remains subject to local verification. This file distinguishes executed checks from checks that need a camera/display-enabled environment.

## Executed environment

- macOS on Apple Silicon, Xcode 27.0, Swift 6.4 toolchain in Swift 6 language mode.
- Deployment target macOS 15.0.
- Builds use the checked-in shared `GravelFit` scheme and no third-party dependencies.
- This runner restricts compiler-plugin nested sandboxing, Xcode testmanager services, GUI launch and IOSurface transport. The command-line compiler option documented in README allows trusted Apple macros to compile while retaining the surrounding workspace and app sandboxes.

## Portrait capture, trimming and frame inspection — October 14, 2026

- Debug app and standalone test bundle rebuilt successfully for arm64 and x86_64 with the documented compiler-plugin workaround.
- Final focused run: **42 passed, 0 failures**. It covers portrait selection and session metadata, decoded-frame display when Vision fails, manual labels without pose measurements, decode/pose timeouts, cancellation, stale-result rejection, persistence, and native interface rendering.
- Real H.264 passthrough export checks passed: a 0.2–0.8 s cut has a 0.6 s duration and a zero-based track timeline, the source remains unchanged, and a portrait movie retains its 240×320 display orientation. Generated compressed fixtures are included with reproduction commands in `GravelFitTests/Fixtures/ATTRIBUTION.md`.
- Original sessions and baselines remain intact when preparing cuts. In-range annotations are rebased to the new clip; out-of-range labels are excluded. These changes persist across repository reloads.
- The full run discovered **48 tests: 45 passed, 1 skipped, 2 failed**. The skipped video/Vision integration reports denied IOSurface transport (`-6662`). The two photograph tests fail with Vision error 9, "Unable to setup request in VNDetectHumanBodyPoseRequest". The image path now uses CGImage directly, so it no longer fails at the previous pixel-buffer allocation step; Vision itself still cannot run these requests in this runner.
- Native trim, frame-inspection and iPhone settings/camera screens rendered in light and dark modes. Trim controls and manual-marking controls were visually inspected. Frame-inspection tests use injected images and pose failures to verify responsiveness without relying on restricted decoding or Vision services.
- Logs: `build/verification/video-workflow-build.log`, `video-workflow-full-tests.log` and `video-workflow-focused-tests.log`. Actual iPhone camera capture and fitting-quality Vision results still need local hardware verification.

## Camera shutdown on navigation — October 14, 2026

- Debug app and test bundle rebuilt successfully for arm64 and x86_64 with the documented compiler-plugin workaround.
- Selected biomechanics, chart, repository and native interface checks: **33 passed, 0 failures**. New lifecycle tests verify that stopping live capture clears current readings and cancels measurement capture, requests recording finalization, and remains stopped when a delayed permission request succeeds.
- Leaving Live Bike Fit, opening the separate Settings window and closing the main window call the shared shutdown method. Calibration dismissal stops capture when the current workspace is not Live Bike Fit. Returning to Live Bike Fit requires an explicit Connect.
- Intent and connection identifiers guard asynchronous permission/configuration results and reconnect notifications so they cannot revive a stopped connection.
- Logs: `build/verification/camera-navigation-build.log` and `camera-navigation-tests.log`. Actual camera hardware and movie finalization remain local hardware checks; the tests exercise lifecycle state and delayed authorization without opening a camera.

## Optional bike profiles — October 14, 2026

- Debug app and test bundle rebuilt successfully for arm64 and x86_64 with the documented compiler-plugin workaround.
- Selected biomechanics, chart, repository and native interface checks: **30 passed, 0 failures**. A camera-only fitting test processes reliable pose frames, saves actual angle readings without a bike ID or setup snapshot, reloads/exports the session and confirms a guided adjustment. Additional checks cover optional selection guards, shared recording/import session metadata, existing bike-linked sessions and journal recovery without a profile.
- Fresh storage and deletion of the last bike now retain an empty profile list. Deleting the active profile returns fitting to **No bike profile**; measured profiles remain available for explicit selection.
- Native views rendered in light and dark modes, including Live Bike Fit with no selected profile and the empty Bike Profiles workspace. Screenshots are in `build/verification/interface/`.
- Logs: `build/verification/optional-profile-build.log` and `optional-profile-tests.log`. The existing hardware-dependent pipeline limitations below were not re-tested for this change; no actual camera recording or iPhone was exercised.

## Bike profile editing changes — earlier October 14, 2026

- Debug app and standalone test bundle rebuilt successfully for arm64 and x86_64 with the documented compiler-plugin workaround.
- Focused repository and native interface checks: **8 passed, 0 failures**. These covered saved profile edits, deletion with session/video preservation, recording/adjustment guards and failed-write rollback. At that point, active-bike deletion selected another profile and last-profile deletion created a replacement; the later optional-profile change above supersedes that behavior. Production views rendered in light and dark appearances; the profile screenshots were inspected.
- The broader direct XCTest run: **30 passed, 1 skipped, 2 failed**. The skipped video check reports denied IOSurface/CoreVideo access (`-6662`). The two existing cyclist-photo Vision tests fail while allocating a pixel buffer in `PoseDetectionService.detect(image:time:)`, with Cocoa error 4866. Camera/Vision code and those tests were not changed for this feature.
- Logs: `build/verification/profile-build.log`, `profile-focused-tests.log` and `profile-full-tests.log`. Native screenshots: `build/verification/interface/profiles-light.png` and `profiles-dark.png`.

## Executed results — October 13, 2026

| Check | Result |
| --- | --- |
| Debug app + standalone test bundle, `xcodebuild build-for-testing` | Succeeded, Swift 6 strict concurrency, arm64 and x86_64 slices. |
| Release app, `xcodebuild build` | Succeeded, optimized universal app. |
| Direct `xcrun xctest` | 26 tests discovered: **25 passed, 1 skipped, 0 failures**. |
| Video/Vision integration | Skipped specifically for AVFoundation underlying OSStatus `-6662`; runner reports denied IOSurface/CoreVideo transport. Test retained for local execution. |
| Video fixture metadata / invalid-video rejection | Passed without hardware decoding. |
| Plist, entitlement, privacy manifest, project syntax | `plutil -lint` passed. |
| Release code signature | `codesign --verify --deep --strict` passed. |
| GUI launch | Unverified: Launch Services returned `-10827`; direct sandboxed launch exited 134 without a usable UI. System log access is denied in this runner, so the startup cause could not be diagnosed here. |
| Actual camera / iPhone / long-session performance | Not tested on compatible hardware. |

Build and XCTest logs are preserved locally under `build/verification/` (ignored generated files). `README.md` contains the exact build/test commands, including the command-line compiler-plugin workaround used here. No Swift source compilation warnings remain; Xcode emits runner service diagnostics and an expected App Intents metadata-extraction notice because this application does not use App Intents.

## Local hardware and interface checks

These checks have **not** been performed on actual camera hardware in this execution environment:

1. Run from Xcode; verify onboarding, light/dark appearance, navigation, window resizing, and the separate analysis window's full-screen mode.
2. On a fresh installation, Connect prompts for camera access. Denying access provides a System Settings link. Verify permission persists with your chosen signing identity.
3. Select a built-in/external camera, then an actual compatible iPhone Continuity Camera. Check selected device identity, available resolution/frame rate and sustained preview latency.
4. Unplug/reconnect the selected camera during preview and recording. Confirm a clear status, recording finalization and rediscovery/reconnection without selecting a different device by name.
5. Complete calibration with a cyclist on a trainer. Check full-body visibility, single-person gating, lighting guidance, anatomical side selection and the ten-second/stroke quality gate.
6. Check skeleton alignment at the image corners and center with each supported rotation and display mirroring. Verify aspect-fit behavior at different window sizes and camera resolutions.
7. Pedal at different cadences. Compare angle geometry against annotated frames, and verify missing-joint values become unavailable. Walk another person into view and confirm measurements are suppressed.
8. Record a long session; inspect memory use, dropped frame behavior, responsive controls, file growth, free-disk handling and quitting during recording. No microphone audio should be captured.
9. Import landscape/portrait movies and an unsupported/corrupt file. Cancel a large import. Check cleanup and responsiveness. Run the retained video/Vision integration test in Xcode with IOSurface access.
10. Step through a movie frame by frame, confirm an actual crank position and annotate TDC/BDC. Verify the saved timestamp and confidence-gated angles. No crank-specific value should appear without annotation.
11. Follow all eight fitting steps, confirm a measured physical adjustment, and capture a fresh result. Validate before/after measurements and the requirement to finish remeasurement before another adjustment.
12. Save a baseline and another fit. Check shared playback controls, positive/negative alignment offsets, extrema, graphs, hip-motion comparison and logged changes.
13. Export CSV, JSON and summary to a user-selected directory. Restart and verify sessions, annotations, profiles and settings. Delete one session, then all data. Confirm corresponding files are removed.

Reference ranges are configurable observations. Detection confidence is not angular accuracy, and side-view measurements do not establish lateral pelvic movement or anatomical hip flexion.
