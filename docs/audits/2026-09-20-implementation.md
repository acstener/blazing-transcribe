# Core experience implementation

Branch: `codex/core-experience-audit`. Existing download-progress edits and experiments preserved. No production installation or release was replaced.

## Changes

- Four primary destinations: Home, History, Dictionary and Settings. Home shows effective capture state, the configured shortcut and recent text; detailed dictation, cleanup, audio, shortcuts and usage controls live in Settings.
- Turbo is explicitly experimental, both in Settings and the menu bar. Its active-microphone requirement is explained, and the standby switch is disabled when the current engine requires continuous capture rather than implying an off setting is honored.
- Home and menu bar share microphone-state presentation. Pausing uses the explicit mic toggle path, including manual standby. Idle sleep defaults are registered centrally at launch (15 minutes, preserving saved choices).
- Dock preference no longer depends on window visibility. Reopen restores/de-miniaturizes the named main window or creates a replacement. Open Blazing Transcribe is the first menu-bar action.
- Onboarding uses a stable manual path, waits for actual engine readiness, provides model retry, and teaches one shortcut before introducing configuration. Real engine results drive the practice success state; ordinary editor input does not count.
- Practice re-entry skips the welcome screen, restores prior mode/preset when closed, and routes text into the practice field only while the app is active. Mode-toggle double presses are ignored during onboarding/practice.
- Fn guidance opens Keyboard Settings and explains both the fn/Globe action and Apple Dictation shortcut. An inline alternative-shortcut editor uses the existing collision validation. System preferences are not silently rewritten. Apple reference: https://support.apple.com/en-qa/guide/mac-help/kbdm162/mac and https://support.apple.com/en-sa/guide/mac-help/mh40584/mac.
- Hidden retained tabs are hidden from accessibility. Mic/Dock controls have accessible names. Onboarding scrolls when expanded help exceeds window height.

## Validation

- `swift build --force-resolved-versions`: passed; existing dependency/compiler warnings remain.
- Added six microphone presentation tests, including stopped capture with stale listening state, active manual standby, error precedence, and engine not ready after loading ends.
- 26 targeted tests passed across microphone presentation, shortcut settings/capture, mode eligibility and text delivery.
- The normal full test invocation is blocked by four existing test files referring to removed licensing/free-tier APIs. To test the remaining code without changing the repository manifest, a temporary package manifest excluded only AppViewModelLicensePresentationTests, FreeTierUpgradeModalPresentationTests, FreeTierUsageTrackerTests and LicenseManagerEntitlementTests, using the repository's pinned Package.resolved.
- The broader temporary-manifest run executed 237 tests: one skipped and two failures in unchanged trial/license onboarding-migration assertions. These were not repaired as part of the UI change. The targeted run is green; the full suite is not.
- Visually inspected Home, Settings, setup and dictation practice in a separate debug preview bundle that skips audio capture, global hotkeys, model loading and analytics. Confirmed direct practice entry, expandable fn instructions and scrolling; entering text manually does not reveal Continue or a success state. Closing and reactivating the preview recovered a main window.

## Remaining device validation

Real microphone capture, cold/warm latency, first-word preservation, fn interception with different macOS keyboard configurations, denied permissions on a clean Mac, and Dock/menu-bar-only lifecycle combinations still need a signed-app walkthrough. The isolated visual preview does not validate those OS integrations. No speed benchmark or new latency guarantee is implied.

The debug preview is enabled by `--experience-preview` or bundle identifier `com.blazingtranscribe.experience-preview`. It is not a production recording session. The initial pass concentrated on the core flow; the second pass below extends the visual system to adaptive appearance and secondary screens.

## Second design pass — reduction and Flow reference

Inspected Wispr Flow's live Dictation and General Settings screens through computer use. Adopted the useful layout principles: an inset content surface, compact grouped preferences, aligned transcript rows, and secondary actions kept quiet. Did not add Flow's promotional, team, referral, transformation or account surfaces.

- Replaced the large slogan with a centered readiness state, shortcut keycap and single practice action. A compact recent-result surface and mic control complete the screen.
- Narrowed navigation; moved Settings to the bottom. General opens with Shortcut, Microphone and Dictation rows; appearance, permissions and support details expand on demand.
- Menu bar now has six rows: status, Pause/Resume microphone, Open Blazing, History, Settings and Quit. Removed configuration submenus, updates and diagnostics from this surface. Updates and both diagnostic actions remain in Settings.
- Menu refreshes state on opening. History/Settings destinations persist through window recreation. Added the standard Command-comma Settings action.
- Stable waveform menu-bar symbol with capture tooltip; fixed icon width. Recording still has its existing red tint.
- Adaptive light/dark colors replace forced Aqua; reduced card shadows. Settings tabs collapse to a menu only when the window is too narrow.
- Punctuation-only latest results display a no-words message and link to the original history entry; stored content is unchanged.
- 18 targeted mic-state, shortcut and history-store tests passed using the same temporary-manifest workaround noted above. Full suite limitations remain.
- Inspected the new main screen in light and dark appearance, plus settings and the actual compact NSMenu in the isolated preview. Real mic/OS permission limitations from the first pass still apply.

## Installed local test build

- Installed signed release build in `/Applications/Blazing Transcribe.app` on 20 September 2026. Version 2.1.2, marked `BlazingLocalTestBuild` in Info.plist and labelled in General settings.
- Same bundle identifier and Developer ID designated requirement as the previous installed release; microphone and Accessibility grants were retained and verified in the live UI.
- Verified live Home reaches “Ready to dictate” with “Mic active · fast standby”; existing settings and history are retained. Human speech-to-text accuracy still needs the user's hands-on test.
- Public Sparkle automatic checks are disabled for this build; manual update action explains this is a local test.
- `build/latest-test-build.txt` records the packaged app. `build/latest-rollback.txt` records the previous release zip. Previous installed bundle is also kept beside that zip as `Blazing Transcribe.previous-app`.
- Rebuild using `SIGNING_IDENTITY='Developer ID Application: Alex Christou (MRJW6XNT7S)' Scripts/build-test.sh`. Script packages only; installation is a separate step. It does not publish or notarize.
- SwiftPM resource accessors are rebuilt from generated compiler argument arrays to resolve `Contents/Resources`; dependency checkouts are unmodified. Embedded Sparkle code is signed inside-out, followed by strict deep verification.
- Release compilation and installed bundle signature verification passed. Earlier targeted tests: 18 passed. Full suite remains blocked by existing removed-license API tests; broader filtered suite had two existing onboarding/license expectation failures.

### Hands-on checks

1. Hold fn in a text field, speak, release; confirm text appears once in the intended app.
2. Pause/resume the microphone and check that the status matches capture behavior.
3. Close and reopen the window from the menu bar and Dock. Toggle Dock visibility under General and confirm the menu bar remains available.
4. Open Try a dictation, complete practice, and confirm the previous recording preferences are restored.
5. Confirm History, Dictionary and Settings remain reachable without adding controls back to the core Dictate screen.

### Settings navigation refinement

Removed the segmented top tab bar. Settings now temporarily uses the existing left sidebar for its sections, with Back to Dictate above the list and Experimental at the bottom. This avoids stacking two navigation systems and preserves content width on smaller windows. Built, signed and installed the revision; verified General → Dictation → Back to Dictate in the live app. The engine returned ready with fast standby active. Five logo concepts were generated as a preview comparison board; no new logo is applied pending selection.

### Resonance identity

User selected fire/voice concept 03. Implemented the three-ribbon flame as `BlazingMark`, a shared native vector shape for the sidebar, Dictate hero and template menu-bar image. Exported the matching outline to `Resources/BlazingResonance.svg`. Release build and strict signature verification passed; installed and visually checked the new mark in the live app. The previous installed build is retained beside the new packaged app.

### Recent transcript overlap fix

Reproduced the Home card overflow after selecting transcript text: macOS selectable Text rendered beyond its three-line layout into the footer. The preview now explicitly disables selection, fits vertically at the available width, truncates to three lines and clips its drawing bounds. The separate Copy button retains full-transcript copying. Signed release build and verification passed; installed and visually verified the same long transcript, attempted selection by dragging, and resized the window from 998 to 722 points wide. Timestamp and Copy remain separated below the preview. Restored the original window size after verification.
