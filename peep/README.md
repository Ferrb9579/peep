# peep

WebRTC peer-to-peer messaging prototype.

## Run locally

Start the signaling relay:

```sh
cd peep-engine
cargo run
```

Start the Flutter web client:

```sh
cd peep
flutter run -d chrome
```

Open the app in two browser tabs with the same room, then connect both. The
first tab waits and the second tab starts the WebRTC offer automatically.
Signaling goes through `ws://127.0.0.1:8787/ws`; chat messages move over the
WebRTC data channel after the peers connect.
