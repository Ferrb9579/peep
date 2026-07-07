enum PeerStatus {
  idle,
  signaling,
  waitingForPeer,
  connecting,
  connected,
  disconnected,
  failed,
}

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
  });

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;

  bool get canSend => false;

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

  Future<void> disconnect() async {
    onStatus(PeerStatus.disconnected);
  }
}
