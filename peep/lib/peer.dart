// One platform boundary for the application and its screens.
library;

export 'webrtc_peer_stub.dart'
    if (dart.library.io) 'webrtc_peer_native.dart'
    if (dart.library.html) 'webrtc_peer_web.dart';
