# Build 135 follow-up: persistent evidence, unchanged transport

Baseline: `cdf4227dc6a966b20e24f61179ac953b22689024`, published `v135`.
Branch: `investigate/135-media-controls`. This work adds diagnostics only. The
build 135 retained-session mapping, native Pause/release boundary, playback
intent, focus policy, preview ownership and chapter navigation are preserved.
No dependency runtime version or progress-file format changes. No automatic startup restoration
or audible resume has been added. Headset Next/Previous remain no-ops, now logged
as unsupported so they can be distinguished from lost commands.

The app declares AndroidX Media 1.7.0 directly to compile its read-only controller
observer. This is the same version already supplied by audio_service 0.18.19;
that plugin's implementation dependency is hidden from the app compile classpath.

## Capture and retrieval

Open **Audio diagnostics** (bug icon) from the library or narration screen, then
**Share diagnostic log**. Android shares a private-cache text attachment using a
non-exported FileProvider with a temporary read grant. Opening diagnostics and
exporting do not issue transport commands. Collection is local; nothing uploads
automatically. Sharing is an explicit user action.

If controls fail, press external Pause once, note whether audio was audible and
whether it stopped, then open diagnostics and share before force-stopping if
possible. After a restart, Share still retrieves the retained files. Record the
Android version and whether Bluetooth had disconnected or reconnected. Do not
infer an overnight failure or process death from the time it was discovered.

The Dart journal has two 256 KiB files; the independent native journal has two
64 KiB files. Each writer has a bounded queue (128 Dart entries, 64 native tasks).
An exported attachment uses one fixed cache filename (approximately 640 KiB).
Rotation retains recent events, not a guaranteed number of days. Both logs and
the export occupy bounded storage; queued events can be lost on an abrupt kill.
Overflow and I/O-failure counters are included. Files persist across process
restarts and ordinary in-place app updates, but not uninstall/clear-data.

Only event names and allowlisted scalar fields are persisted. No book text,
titles, authors, paths, URLs, raw exception messages, device names/addresses,
credentials or tokens. A non-cryptographic opaque numeric book tag helps correlate
chapter loads; it is not an anonymization guarantee for predictable book IDs.
Session-token hash values identify a local session; they are not token contents.
The log contains timestamps, positions and chapter indices, so it remains user
diagnostic information. Console verbosity is off unless
`DOGREADER_MEDIA_VERBOSE=true` is supplied at build time. The existing in-memory
diagnostic view remains available.

## Events and limits

- Dart: process/handler creation, session configuration, chapter restore/load,
  unique playback-state transitions, focus events, command receipt, queued
  execution, completion/cancellation and numeric player errors. A session-bridge
  error is a separate event; its raw message is never written to the journal.
- Native: process/activity events, existing controller/token observation,
  session-ready/destroyed callbacks, native playback-state transitions, observed
  service PID/start time/foreground flags, available output-device types, and up
  to three previous process-exit records on Android 11+.

There is no polling, extra wake lock, audio session, focus request, media-browser
binding, transport command, or Bluetooth permission added by the observer.
Position-only state updates are deduplicated. Disk writes run asynchronously;
transport never waits for diagnostics. Native observation starts with an activity
and attaches to the already registered media controller after AudioService.init.
It does not cover a wholly headless startup before an activity exists.

`service_observed` is a snapshot, not an instrumented service lifecycle callback.
`service_not_observed` does not prove destruction. Output-device callbacks show
available devices, not the route used by the player. A sudden process kill need
not invoke session/activity destruction callbacks. Controller observation does
not repair a connection or directly instrument plugin media-button ingress; the
Dart command-receipt event shows whether delivery reached the handler. Do not
claim exact Android service creation, native button delivery, competing-session
ownership, or audible playback from these logs alone.

## Focused validation

The dedicated `media-diagnostics.yml` workflow uses locked dependencies, analysis,
the new persistence/privacy/backpressure tests and existing lifecycle, bridge,
transport, ownership, native-boundary and seek regressions. It checks native
journal rotation/restart/failure handling on the JVM and compiles the Android
observer without packaging an APK. It has read-only GitHub permissions and no
release/upload/deploy steps. The separately authorized build-136 release workflow
published the diagnostic APK in successful run `42921560293` at
`6ff767385bd6bfbc59eccd7ec842d74305ef0736`. Physical Android sharing,
route/session observation, restart retention and prolonged use still need device
validation. The older build-135 and release workflows are unchanged.

Analysis, all 50 selected Flutter tests and the native journal JVM checks passed
in run `42916527842` at `c2a56e0`. Workflow/native-classpath-only follow-ups reuse
those results when the Flutter and journal sources are identical. Native
compilation is checked on every run. No APK or release is produced by this workflow.
