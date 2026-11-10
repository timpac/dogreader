# Dogreader Build 136 — persistent media diagnostics

Install **Dogreader-136.apk** over build 135. Keep the existing app installed and
keep its data; this update uses the original package and signing identity.

This diagnostic build preserves build 135's media-session lifecycle correction
and playback behavior. It adds bounded logs that survive process restarts and a
**Share diagnostic log** action, accessible through the bug icon on the library
or narration screen. Logs record commands, playback/focus changes, chapter
loading, native session observations, output-device types and available process
exit information. Nothing uploads automatically.

Persisted logs exclude book text, titles, credentials, paths, URLs, device names
and raw error messages. Logs contain timestamps, positions and chapter indices.
Storage is bounded and normal console verbosity is off.

If external controls fail, press external Pause once and note whether audio was
already playing and whether it stopped. Open **Audio diagnostics → Share** before
force-stopping if possible. After restarting, the retained logs can still be
shared. Note the Android version and any Bluetooth disconnect/reconnect.

The intermittent failure's cause remains unconfirmed. This release gathers
evidence; it is not a claim that the remaining problem is fixed. Previous/Next
headset commands retain their existing unsupported behavior and are now logged.
No automatic audible playback after process recreation has been added.

Source is unchanged from diagnostic implementation
`c4cd87075448790b324d243b71ae3f551f74a399`; subsequent release preparation changes
workflow and documentation only. Analysis, all 50 selected Flutter regressions,
native journal checks and Android compilation passed. Physical sharing,
Bluetooth/session observation and prolonged device use still need validation.

Original package: `com.example.audiobook_app` · version code: `136`.
