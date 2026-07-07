enum PeerStatus {
  idle,
  signaling,
  waitingForPeer,
  connecting,
  connected,
  disconnected,
  failed,
}

enum CallState { idle, outgoing, incoming, active }

class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.isLocal,
    required this.sentAt,
  });

  final String text;
  final bool isLocal;
  final DateTime sentAt;
}

class PeerClient {
  PeerClient({
    required this.onStatus,
    required this.onMessage,
    required this.onLog,
    required this.onMediaChanged,
  });

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;
  final void Function() onMediaChanged;

  bool get canSend => false;
  bool get cameraEnabled => false;
  bool get microphoneEnabled => false;
  CallState get callState => CallState.idle;
  bool get callActive => false;
  String? get localVideoViewType => null;
  String? get remoteVideoViewType => null;

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
  }) async {
    onStatus(PeerStatus.failed);
    onLog('WebRTC chat is currently implemented for Flutter web builds.');
  }

  void send(String text) {
    onLog('Cannot send until a web data channel is connected.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    onLog('Camera controls are only available in Flutter web builds.');
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    onLog('Microphone controls are only available in Flutter web builds.');
  }

  void startCall() {
    onLog('Calls are only available in Flutter web builds.');
  }

  Future<void> acceptCall() async {
    onLog('Calls are only available in Flutter web builds.');
  }

  void declineCall() {
    onLog('Calls are only available in Flutter web builds.');
  }

  Future<void> endCall() async {
    onLog('Calls are only available in Flutter web builds.');
  }

  Future<void> disconnect() async {
    onStatus(PeerStatus.disconnected);
  }
}
