# Peep

Peep is a Flutter messaging and calling application with a Rust signaling and
media server. It supports username-based accounts, direct and group conversations,
encrypted audio/video attachments, calls, screen sharing, and Android notifications
with inline replies.

## Run locally

Start the engine in a separate terminal:

```sh
cd ../peep-engine
cargo run
```

Start the client from this directory:

```sh
flutter run -d chrome
```

The default engine endpoint is `ws://127.0.0.1:8787/ws` on web and desktop, and
`ws://10.0.2.2:8787/ws` on Android emulators. Set a different endpoint in Connection
settings or at build time:

```sh
flutter run --dart-define=PEEP_SIGNALING_URL=wss://your-server.example/ws
```

Create two accounts, then start a conversation using the other account's username.
Direct messages travel over an encrypted WebRTC data channel. After the two clients
establish a conversation key, the engine can hold encrypted messages while a peer
is offline. Group messages travel as encrypted WebSocket broadcasts, and group
calls use the engine's SFU. Android release notification connections require WSS.

Audio/video attachments are limited to 8 MiB. Empty or unsupported files are
rejected before sending, and received chunks are bounded and validated before
playback.

The engine listens on `127.0.0.1:8787` by default (`PEEP_ENGINE_ADDR` overrides this).
Its SQLite path defaults to `peep-mailboxes.sqlite3`; use `PEEP_DB_PATH` or
`PEEP_MAILBOX_PATH` to choose another database.

## Everyday controls

- Each direct and group conversation keeps its own unsent draft for the current
  signed-in session, including cursor position. Leaving and reopening a chat
  restores it; sending clears it. Drafts are kept in memory and disappear after
  sign-out, app restart, or browser reload.
- On desktop, **Enter** sends and **Shift+Enter** inserts a line. Sending keeps
  the composer focused. Input methods can finish composing before a send.
- Incoming messages follow the latest view when you are already there. While
  reading earlier messages, they leave your position alone and show a new-message
  count. **Jump to latest** catches up.
- **Search messages** filters the open conversation by text, attachment name,
  or sender. **Ctrl/Cmd+F** opens it and **Escape** closes it. Closing search
  restores your previous reading position.
- Each message's menu offers **Copy message** and **Quote in reply**. Quotes
  become plain text in the composer and preserve the existing draft.
- **Ctrl/Cmd+K** focuses inbox search. **Escape** clears it; **Reset filters**
  recovers from an empty search/unread view. Refresh and attachment actions
  prevent duplicate requests while pending.
- Call shortcuts: **M** toggles the microphone, **V** the camera, **F** expands
  video, **G** switches layout, and **Escape** exits expanded video. The keyboard
  button lists them on desktop. A reminder stays visible while muted.
- Media settings show unsaved edits, offer **Restore defaults**, and confirm a
  successful save. Screen-only defaults preserve camera and audio preferences.
- Button press, icon, tab, and ringing transitions respect reduced motion.

## Call and media preferences

Incoming calls have an accept/decline screen; outgoing calls show ringing and
can be canceled. An unanswered direct call times out after 60 seconds. Completed
calls show the outcome and conversation duration, with **Call again** (or
**Rejoin call** for groups) and **Back to chat**. Call history records incoming
and outgoing outcomes; ringing time is excluded from the duration.

Tap a video tile to expand it within the app. Pinch or scroll to zoom up to 4×,
drag to pan, double-tap to toggle 2× zoom, or use the zoom/reset buttons. Escape,
the exit button, or system Back restores the participant layout. The expanded
view also closes when that participant's video stops. Direct calls show the
other person with a compact self preview; the layout switch enables balanced
tiles, and group grids adapt to the available space.

Open **Settings → Call & media quality**, or the tuning button in a conversation
or call. Preferences are saved on this device and shared by direct and group calls.

- Data saver, balanced, and high-quality presets.
- Preferred video and audio codecs discovered from the device's WebRTC capabilities.
- Video capture resolution: 360p, 480p, 720p, or 1080p.
- Camera and screen frame-rate limits: every whole value from 1–60 fps.
- Separate screen resolution: original size, 720p, 1080p, 1440p, or 4K.
- Screen bitrate ceiling: 100–20000 kbps; numeric entry supports exact values.
- In-call screen controls: start/stop, pause/resume, change source, and screen quality.
  Canceling a replacement source selection preserves the existing share.
- Camera bitrate ceiling: 250–8000 kbps; audio: 24–256 kbps. All bitrate
  controls accept exact numeric values as well as sliders.
- Audio capture quality requests: 16 or 48 kHz, mono or stereo.
- Echo cancellation, noise suppression, and automatic gain control.

Bitrate and frame-rate limits apply to current outgoing senders. Codec preferences
apply during the next offer/answer negotiation. Camera resolution changes apply
when the camera is acquired again. Screen capture constraints apply live on web;
on native devices, select the source again to apply a new capture resolution.
Pausing disables the screen video sender and track while microphone audio stays
active. Camera and screen settings are saved independently. Audio capture and processing changes apply
when a new microphone track is acquired, usually in the next call. Native capture
support varies by platform; settings are requests rather than guaranteed formats.

Compatible codecs remain available as fallbacks. The remote peer or group server,
hardware, and network conditions determine actual delivered quality. A bitrate
ceiling controls outgoing media, not incoming bandwidth. The implementation uses
[`setCodecPreferences` and sender `setParameters`](https://www.w3.org/TR/webrtc/)
rather than editing codec lists in SDP.

## Code organization

- `lib/main.dart`: application state and coordination of authentication, chats,
  persistence, notifications, and calls.
- `lib/peer.dart`: the conditional export selecting native, web, or stub transport.
- `lib/ui/`: account, inbox, conversation, call, and media-settings screens, plus
  the shared theme, branding, and avatars. Screens communicate through callbacks.
- `lib/media/`: immutable preferences, local persistence, codec ordering, and
  platform-specific WebRTC codec/sender configuration.
- `lib/models/conversation_id.dart`: canonical direct-conversation identifiers.
- `lib/models/call_session.dart`: call outcomes, direction, and duration tracking.
- `lib/storage/`: secure local message-history storage.
- `../peep-engine/src/`: account/group/key/mailbox/conference stores and SFU.
- `android/app/src/main/kotlin/`: notifications, inline replies, and screen sharing.

Keep native, web, and stub APIs aligned when changing platform-facing features.
Presentation code should depend on `peer.dart` rather than repeating conditional
imports. Do not put sample conversations into the production application.

## Verify changes

```sh
flutter analyze
flutter test
flutter build web --release
flutter build apk --debug
```

Tests cover encryption, inbox navigation/search, group-creation errors, account
validation, call participants, the composer, media presets, codec fallbacks, and
preservation of negotiated sender parameters.

A separate development gallery uses sample data and the real screen widgets:

```sh
flutter run -d web-server -t tool/ui_preview.dart --web-port 8899
```

For a browser WebRTC loopback check without camera or microphone access:

```sh
flutter run -d web-server -t tool/media_smoke.dart --web-port 8898
```

Open the printed URL. The check creates synthetic video/audio, establishes a local
peer connection, verifies preferred-codec ordering and sender limits, then changes
bitrate and frame-rate limits on the negotiated connection. It releases its tracks
and connections after completion. This does not validate physical-device capture
or a production SFU/network deployment.

For headed testing of the real application with synthetic devices:

```sh
flutter run -d web-server -t tool/headed_qa.dart --web-port 8902 \
  --dart-define=PEEP_SIGNALING_URL=ws://127.0.0.1:8877/ws
```

Use an isolated engine database and separate browser origins/ports for each test
account. This entrypoint replaces browser capture with generated audio/video,
keeps the production UI and transports, and displays a QA banner. Add
`?media=denied` to reject the first capture request, `?media=missing` to reject
every request, or `?media=missing-video` to allow audio and reject camera/screen
capture. It never requests a physical camera or microphone. The production
entrypoint remains `lib/main.dart`.
