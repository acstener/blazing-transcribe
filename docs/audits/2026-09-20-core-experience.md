# Core experience and new-user audit

Date: 20 September 2026. Branch: `codex/core-experience-audit`.

## Scope and evidence

Inspected the running macOS application's Dashboard, History, Dictionary, Shortcuts, Audio, Settings and Stats through screenshots and accessibility trees. Reviewed onboarding, window lifecycle, capture policy, idle sleep and design-system source. The installed binary was not rebuilt or verified to match the checkout exactly. Findings below distinguish visual observations from source findings; no cold-install onboarding, live dictation, latency benchmark or permission reset was performed. Existing uncommitted download-progress work and `experiments/` were preserved when branching from local `main`. This is an audit and implementation brief, not a shipped redesign.

## Product direction

Make Blazing Transcribe feel like a dependable native Mac utility: immediately findable, explicit about the microphone, and ready to help you dictate. Speed remains central. Premium quality comes from predictable behaviour, restrained presentation and clear recovery as much as typography.

Proposed activation milestone: a user dictates with their configured shortcut and successfully receives text in their intended app. A successful sandbox dictation is an intermediate milestone. Onboarding completion and manually typing in a demo field are not activation.

No funnel or cohort data was queried. Priorities are based on observed friction and implementation evidence, not measured conversion impact.

## Prioritized findings

| Priority | Finding and evidence | User impact | Recommended change |
| --- | --- | --- | --- |
| P0 | `AppDelegate.shouldKeepCaptureRunningBetweenManualPresses` forces capture for manual realtime even when Keep Mic Active is off. `KeepMicActiveControl` only explains a forced-on state for Always-on. Source finding. | A privacy-related control can promise a state the engine does not honor. | Derive displayed capture state and available controls from the actual policy. Either implement genuine mic-off realtime safely or explain the limitation and offer an explicit switch to a compatible mode. Never silently override the choice. |
| P1 | `syncActivationPolicyToWindowVisibility` requires a visible/minimized window to retain regular activation policy, even when Show icon in Dock is enabled. Source finding consistent with the user's report. | Closing the window can make the app disappear from the expected place. | Make Dock preference independent of window visibility. Default to a regular Mac app; menu-bar-only remains an explicit preference. |
| P1 | `showMainWindow` searches for the first eligible existing window and logs a failure if none exists. No `applicationShouldHandleReopen` implementation found. Source finding; failure not reproduced live. | App launch/reopen can feel unreliable and the wrong eligible window could be targeted. | Use the named main scene/window. Restore and deminiaturize it, or recreate it if absent. Wire Dock/Finder reopen and menu-bar Open to the same path. |
| P1 | Dashboard visibly starts with Mode, Speed, Text Cleanup and mic settings; no prominent readiness, current capture state or first action. | The product opens as a control panel rather than a useful starting point. | Build a Home screen around current status, configured shortcut, a contained practice field and latest result. Move detailed configuration into Settings. |
| P1 | Try It introduces Manual/Always-on and Stable/Turbo before a first successful result; includes the phrase “VAD auto-detects speech.” Source finding. | Users must understand engine tradeoffs before seeing value and may change focus away from the practice field. | Use one dependable initial path. Teach hold/release with the actual shortcut. Offer advanced modes after success. |
| P1 | TrialStep celebrates completion even after Skip; TryItStep tracks first transcription on any nonempty editor change. Source finding. | Completion can imply success that never happened; activation measurement accepts typing. | Track actual transcription/delivery events. Separate “setup finished” from “first dictation worked”; provide a persistent unfinished-setup recovery action. |
| P1 | Idle sleep stops capture, but its state is not prominent on the live dashboard. Source distinguishes sleeping from resumed capture poorly at the product level. | A hands-free user may speak to a sleeping microphone and interpret silence as failure. | Show “Mic asleep” plus an explicit wake action and configured shortcut. Explain that speech cannot wake a stopped microphone. |
| P1 | UI uses a 15-minute AppStorage fallback, while timer reads an absent integer default as zero; nearby engine comments describe opt-in. Source finding; fresh-install persistence behavior needs verification. | New users may see a duration that does not match effective policy. | Register one shared default and test a fresh defaults suite before any settings view is opened. Preserve explicit existing choices. |
| P2 | Live Audio view shows device rows with no clear selected indicator in the observed state; the neutral meter has no off/asleep explanation. | It is hard to tell which microphone will be used or whether input is working. | Show selected/effective input and availability; pair the meter with a state label. Offer a deliberate mic test. Put sensitivity controls in a collapsed Advanced section. |
| P2 | History visibly contains empty and punctuation-only entries alongside valid dictations. Existing recovery is available for some entries through row actions. | The archive can look unreliable and leaves the user to infer what happened. | Distinguish no speech, transcription failure and delivery failure. Keep valid text easy to copy and retain useful recoverable attempts; investigate punctuation-only output before filtering it. |
| P2 | Shortcuts repeatedly uses “Record” for binding capture, with prominent Reset controls and a long explanatory preamble. | “Record” is ambiguous in a recording product; destructive/revert actions compete with editing. | Use “Change shortcut”; show a live capture state and concise per-row guidance. Put reset in a secondary action. Teach the first shortcut before advanced gestures. |
| P2 | Dictionary leads with phonetic implementation detail and “We're improving this over time.” | It sounds unfinished and does not first explain the benefit. | Lead with “Help Blazing recognize names and specialist words.” Add examples; move aliases into an advanced editor. |
| P2 | Seven navigation destinations, repeated white cards, many equally prominent options; Dashboard lacks the heading pattern used elsewhere. Stats tiles use only part of available width. | Hierarchy and layout feel assembled feature by feature. | Use Home, History, Dictionary and Settings as primary navigation; group Audio and Shortcuts under Settings. Treat Stats as secondary usage information. Standardize content widths and headers. |
| P2 | On-state switches appeared neutral/gray; tiny low-contrast shortcut hints and metadata were visible. Accessibility tree exposes unnamed toggles. | State and action are harder to read, especially with assistive technology. | Consistent accent for selection, explicit accessibility labels/value, visible keyboard focus and measured text contrast. Do not rely only on color. |
| P2 | Main app explicitly forces Aqua and uses fixed light color tokens. | App appearance does not follow the user's environment. | Introduce semantic light/dark surfaces, validate contrast in both and preserve overlay-specific appearance needs. |

## Proposed first-use flow

1. **Welcome and setup:** “Turn your voice into text in any app.” One primary action. Explain microphone access as hearing dictation and Accessibility as inserting text into the selected field. Show each permission's actual state, download byte progress, preparation state and recoverable errors. Keep retry/help available. Do not equate “not loading” with engine readiness.
2. **First dictation:** default to the dependable manual path with a clearly disclosed microphone policy. Show the configured shortcut, a sample sentence and a contained editable practice area. States: ready → starting microphone → recording → transcribing → result, with recovery for every failure. Keep focus reliable after interacting with controls. Verify the transcript came from the engine before celebrating.
3. **Use it in your app:** “Click a text field in any app, hold [shortcut], speak, then release.” Explain where to reopen Blazing and show its menu-bar symbol. Offer practice again. Count successful external delivery separately; if only copied, say so.
4. **Optional personalization after success:** offer fast standby and hands-free behavior with explicit mic explanations; postpone cleanup models, API providers and sensitivity tuning. Skipping personalization should not affect core readiness.

Allow exiting setup, but Home must then show the next unresolved setup action. Never strand a user behind a disabled Continue with no recovery. A returning user should resume the incomplete step, not repeat completed permissions or downloads.

## Microphone product contract

Apple documents the orange indicator as microphone use: [Use Control Center on Mac](https://support.apple.com/en-om/guide/mac-help/mchl50f94f8f/mac). The product should make capture understandable and controllable. Stopping this app's capture does not guarantee all system microphone indicators disappear if another app is using the mic.

Separate the speech model's warm state from microphone capture. Keeping a model in memory can avoid model loading, but it does not establish that opening the audio device is instantaneous. The current ~0.7-second cold-start statement is app copy, not a benchmark verified in this audit.

Proposed user-facing choices, subject to engine validation:

| Choice | Behaviour | Honest explanation |
| --- | --- | --- |
| Mic only while dictating | Stop capture between manual recordings; retain model readiness where possible. | “Microphone off between recordings. Starting a recording may take a moment.” |
| Fast standby | Keep capture active between manual recordings; sleep after an explicitly selected interval. | “Microphone stays active for faster starts. macOS shows its microphone indicator.” |
| Hands-free | Listen and insert speech without holding a shortcut while enabled. | “Microphone listens while hands-free is on. If it sleeps, use [shortcut] or Resume to wake it.” |

Suggested direction: recommend mic-only during first use, then offer fast standby after the first success. Preserve existing users' preferences. This is a product recommendation, not a change applied by this audit. Measure cold-start first-word loss and p50/p95 press-to-capture time before choosing the final default. If realtime cannot honor mic-only, explain and let the user choose a compatible mode; do not keep the mic open behind an off switch.

Show one truthful state across Home, menu bar and overlay: **Mic off**, **Mic active · fast standby**, **Listening · hands-free**, **Starting microphone**, **Recording**, **Transcribing**, **Mic asleep**, or **Needs attention**. Avoid calling live capture simply “Ready.” Provide a reachable Pause/Resume control. Keep active-capture indication separate from model readiness.

## Home and visual direction

Home's primary content is a status heading and the next useful action. Secondary content is the configured shortcut and a practice/result surface. Tertiary content is recent history and a compact link to microphone preferences. Detailed mode, engine, cleanup and provider settings should not dominate the first screen.

Suggested hierarchy:

```text
Home                                    Settings

Mic off
Hold [configured shortcut] to dictate
Microphone activates when you start recording.

[ Practice dictation                                      ]
[ Your words appear here.                                ]

Recent dictation                          View history →
Latest useful result, with Copy and delivery status
```

Keep the existing warm neutral character. Use one accent for active choices and primary actions; semantic colors only where state requires them. Prefer fewer containing surfaces and more deliberate grouping.

- Spacing: retain 4, 8, 16, 24, 32, 48 pt; 32 pt content inset, 24 pt between groups, 8–16 pt within groups.
- Type: 24 pt semibold screen titles, 17 pt semibold section headings, 15 pt body, 13 pt supporting text, 12 pt metadata. Use monospace only for shortcuts and useful measurements.
- Surfaces: semantic window background, grouped surface, primary/secondary text, separator, accent and status colors with light/dark definitions. Existing palette is a useful light-mode starting point.
- Depth: flat grouped rows by default; one subtle shadow for a floating/interactive surface. Avoid a shadowed card around every preference.
- Components: shared page header, labelled selection row, accessible toggle row, status presentation, permission/download row, practice field and actionable empty/error state.
- Motion: short state transitions; honor Reduce Motion. Avoid decorative animation competing with readiness or recording feedback.

## Implementation sequence and acceptance checks

### 1. Reliability and trust

Fix window lifecycle, effective microphone policy and idle default consistency first. Test close/reopen from Dock, Finder and menu bar; minimize/restore; missing main-window recreation; menu-bar-only preference; multiple windows; app already running. Closing a window must not change the explicit Dock preference.

For microphone policy test manual and hands-free, both engine presets, standby on/off, idle sleep/wake, device disconnect and in-flight transcription. Assert actual capture state, not only displayed preferences. Verify the first word after waking and that sleep never interrupts active dictation. Cover absent defaults and saved user choices.

### 2. Activation and Home

Simplify setup and add truthful status plus a practice surface. Test clean install, denied/revoked permissions, interrupted download, model preparation failure, skipped setup, rebound shortcuts and non-default keyboards. Keyboard typing in the practice field must not count as voice activation. Verify safe focus and correct destination delivery after the app window is hidden.

### 3. Premium visual pass

Apply the shared hierarchy to History, Dictionary and Settings. Review all screens at minimum supported size and normal size, light/dark, keyboard-only, VoiceOver and Reduce Motion. Verify active choices and mic state without relying on color. Include empty, loading, offline, asleep and failed states.

### 4. Measurement

Track setup started, permission outcomes, model ready/failure, first recording started, first transcript produced and first external delivery outcome, plus time between them. Separate skipped setup from successful activation. Track subsequent successful use on days 1 and 7 only within the existing telemetry policy; do not add transcript/audio payloads. Report capture startup separately from inference and delivery latency. No “fastest on the market” claim is validated by this audit.

## Remaining validation

Onboarding needs a real clean-profile walkthrough. Record screen evidence of its loading, permission and failure states without resetting the user's main installation. Reproduce the reported window issue against a built checkout. Verify installed-build/source differences before using screenshot findings as exact regression expectations. Obtain actual cold/warm capture measurements before promising the final latency/privacy tradeoff.
