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

class AuthSession {
  const AuthSession({
    required this.token,
    required this.username,
    required this.email,
  });

  final String token;
  final String username;
  final String email;
}

class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.members,
  });

  final String id;
  final String name;
  final List<String> members;
}

Future<AuthSession> createAccount({
  required Uri signalingUri,
  required String email,
  required String username,
  required String password,
}) {
  throw UnsupportedError('Accounts are currently implemented for Flutter web.');
}

Future<AuthSession> signInAccount({
  required Uri signalingUri,
  required String username,
  required String password,
}) {
  throw UnsupportedError('Accounts are currently implemented for Flutter web.');
}

Future<GroupSummary> createGroup({
  required Uri signalingUri,
  required String token,
  required String name,
  required List<String> members,
}) {
  throw UnsupportedError('Groups are currently implemented for Flutter web.');
}

Future<List<GroupSummary>> listGroups({
  required Uri signalingUri,
  required String token,
}) {
  throw UnsupportedError('Groups are currently implemented for Flutter web.');
}

Future<List<MailboxSummary>> listMailboxSummaries({
  required Uri signalingUri,
  required String token,
}) {
  throw UnsupportedError(
    'Mailbox summaries are currently implemented for Flutter web.',
  );
}

Future<void> ensureIdentityKeyPublished({
  required Uri signalingUri,
  required AuthSession session,
}) {
  throw UnsupportedError(
    'Identity keys are currently implemented for Flutter web.',
  );
}

Future<void> ensureGroupKeyPublished({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) {
  throw UnsupportedError(
    'Group keys are currently implemented for Flutter web.',
  );
}

Future<String> loadOrFetchGroupKey({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) {
  throw UnsupportedError(
    'Group keys are currently implemented for Flutter web.',
  );
}

class AttachmentData {
  const AttachmentData({
    required this.name,
    required this.mimeType,
    required this.size,
    required this.dataUrl,
    this.viewType,
  });

  final String name;
  final String mimeType;
  final int size;
  final String dataUrl;
  final String? viewType;

  bool get isAudio => mimeType.startsWith('audio/');
  bool get isVideo => mimeType.startsWith('video/');
}

class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.isLocal,
    required this.sentAt,
    this.sender,
    this.attachment,
  });

  final String text;
  final bool isLocal;
  final DateTime sentAt;
  final String? sender;
  final AttachmentData? attachment;
}

class MediaView {
  const MediaView({required this.title, required this.viewType});

  final String title;
  final String? viewType;
}

class StoredConversation {
  const StoredConversation({
    required this.conversationKey,
    required this.contactUsername,
    required this.lastText,
    required this.updatedAt,
  });

  final String conversationKey;
  final String contactUsername;
  final String lastText;
  final DateTime updatedAt;
}

class MailboxSummary {
  const MailboxSummary({
    required this.room,
    required this.contactUsername,
    required this.unreadCount,
    required this.updatedAt,
  });

  final String room;
  final String contactUsername;
  final int unreadCount;
  final DateTime updatedAt;
}

List<ChatMessage> loadMessageHistory(String conversationKey) {
  return const [];
}

void saveMessageHistory(String conversationKey, List<ChatMessage> messages) {}

List<StoredConversation> listStoredDirectConversations(String username) {
  return const [];
}

class GroupClient {
  GroupClient({
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
  bool get screenShareEnabled => false;
  CallState get callState => CallState.idle;
  bool get callActive => false;
  String? get localVideoViewType => null;
  String? get remoteVideoViewType => null;
  List<MediaView> get remoteVideoViews => const [];

  Future<void> connect({
    required Uri signalingUri,
    required String token,
    required String groupId,
    required String groupKeyBase64,
  }) async {
    onStatus(PeerStatus.failed);
    onLog('Group chat is currently implemented for Flutter web builds.');
  }

  void send(String text) {
    onLog('Cannot send until a web group socket is connected.');
  }

  Future<void> startConference({
    required Uri signalingUri,
    required String token,
    required String groupId,
  }) async {
    onLog('Group calls are currently implemented for Flutter web builds.');
  }

  Future<void> endConference() async {
    onLog('Group calls are currently implemented for Flutter web builds.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    onLog('Group camera controls are only available in Flutter web builds.');
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    onLog(
      'Group microphone controls are only available in Flutter web builds.',
    );
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    onLog('Group screen sharing is only available in Flutter web builds.');
  }

  Future<void> disconnect() async {
    onStatus(PeerStatus.disconnected);
  }
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
  bool get canMessage => false;
  bool get cameraEnabled => false;
  bool get microphoneEnabled => false;
  bool get screenShareEnabled => false;
  bool get encryptionReady => false;
  CallState get callState => CallState.idle;
  bool get callActive => false;
  String? get localVideoViewType => null;
  String? get remoteVideoViewType => null;

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
    String? authToken,
    String? accountUsername,
    String? contactUsername,
  }) async {
    onStatus(PeerStatus.failed);
    onLog('WebRTC chat is currently implemented for Flutter web builds.');
  }

  void send(String text) {
    onLog('Cannot send until a web data channel is connected.');
  }

  Future<void> pickAndSendAttachment() async {
    onLog('Attachments are only available in Flutter web builds.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    onLog('Camera controls are only available in Flutter web builds.');
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    onLog('Microphone controls are only available in Flutter web builds.');
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    onLog('Screen sharing is only available in Flutter web builds.');
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
