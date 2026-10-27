// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import 'storage/encrypted_store.dart';
import 'models/conversation_id.dart';
import 'models/attachment_payload.dart';
import 'media/media_settings.dart';
import 'media/webrtc_media_web.dart';

Future<void> initializePlatformServices() async {}

Future<void> startMessageNotifications({
  required Uri signalingUri,
  required AuthSession session,
}) async {}

Future<void> stopMessageNotifications() async {}

Future<void> showIncomingMessageNotification({
  required String contact,
  required String preview,
}) async {}

Stream<String> get messageNotificationTaps => const Stream.empty();
Future<String?> takeInitialMessageNotificationContact() async => null;

Widget buildPlatformMediaView(String viewType, {bool mirror = true}) {
  return HtmlElementView(
    viewType: viewType,
    onPlatformViewCreated: (viewId) {
      final element = ui_web.platformViewRegistry.getViewById(viewId);
      if (element is html.VideoElement) {
        // Rebuilding the participant grid detaches and pauses existing videos.
        // Resume after Flutter has attached the platform view again.
        html.window.requestAnimationFrame((_) => _resumeVideo(element));
      }
    },
  );
}

void _resumeVideo(html.VideoElement video) {
  if (video.srcObject == null) return;
  // Adding a camera track to an existing audio stream does not restart
  // autoplay after the preview was removed from the widget tree.
  unawaited(video.play().catchError((Object _) {}));
}

void _setVideoStream(html.VideoElement video, html.MediaStream? stream) {
  video.srcObject = stream;
  if (stream != null) _resumeVideo(video);
}

enum PeerStatus {
  idle,
  signaling,
  waitingForPeer,
  connecting,
  connected,
  disconnected,
  failed,
}

bool _hasLiveVideo(html.MediaStream? stream) =>
    stream?.getVideoTracks().any(
      (track) =>
          track.enabled == true &&
          track.muted != true &&
          track.readyState != 'ended',
    ) ==
    true;

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

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      token: json['token'] as String,
      username: json['username'] as String,
      email: json['email'] as String,
    );
  }
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

  factory GroupSummary.fromJson(Map<String, dynamic> json) {
    return GroupSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      members: (json['members'] as List<dynamic>).whereType<String>().toList(
        growable: false,
      ),
    );
  }
}

class AuthenticatedMemberKey {
  const AuthenticatedMemberKey({
    required this.username,
    required this.publicKey,
  });

  final String username;
  final String? publicKey;

  factory AuthenticatedMemberKey.fromJson(Map<String, dynamic> json) {
    return AuthenticatedMemberKey(
      username: json['username'] as String,
      publicKey: json['publicKey'] as String?,
    );
  }
}

Future<AuthSession> createAccount({
  required Uri signalingUri,
  required String email,
  required String username,
  required String password,
}) {
  return _postAuth(
    signalingUri: signalingUri,
    path: '/api/register',
    body: {'email': email, 'username': username, 'password': password},
  );
}

Future<AuthSession> signInAccount({
  required Uri signalingUri,
  required String username,
  required String password,
}) {
  return _postAuth(
    signalingUri: signalingUri,
    path: '/api/login',
    body: {'username': username, 'password': password},
  );
}

Future<AuthSession> _postAuth({
  required Uri signalingUri,
  required String path,
  required Map<String, String> body,
}) async {
  return AuthSession.fromJson(
    await _postJson(signalingUri: signalingUri, path: path, body: body),
  );
}

Future<GroupSummary> createGroup({
  required Uri signalingUri,
  required String token,
  required String name,
  required List<String> members,
}) async {
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/create',
    body: {'token': token, 'name': name, 'members': members},
  );
  return GroupSummary.fromJson(decoded);
}

Future<List<GroupSummary>> listGroups({
  required Uri signalingUri,
  required String token,
}) async {
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/list',
    body: {'token': token},
  );
  final groups = decoded['groups'];
  if (groups is! List) {
    return const [];
  }
  return groups
      .whereType<Map<String, dynamic>>()
      .map(GroupSummary.fromJson)
      .toList(growable: false);
}

Future<List<MailboxSummary>> listMailboxSummaries({
  required Uri signalingUri,
  required String token,
}) async {
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: '/api/mailbox/list',
    body: {'token': token},
  );
  final chats = decoded['chats'];
  if (chats is! List) {
    return const [];
  }
  return chats
      .whereType<Map<String, dynamic>>()
      .map(MailboxSummary.fromJson)
      .toList(growable: false);
}

Future<void> ensureIdentityKeyPublished({
  required Uri signalingUri,
  required AuthSession session,
}) async {
  final identity = await _loadOrCreateIdentityKeyPair(session.username);
  await _postJson(
    signalingUri: signalingUri,
    path: '/api/identity-key/update',
    body: {'token': session.token, 'publicKey': identity.publicKeyBase64},
  );
}

Future<void> ensureGroupKeyPublished({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) async {
  final existing = html.window.localStorage[_groupKeyStorageKey(group.id)];
  final rawGroupKey = existing != null && existing.isNotEmpty
      ? Uint8List.fromList(base64Decode(existing))
      : Uint8List(32);
  if (existing == null || existing.isEmpty) {
    html.window.crypto!.getRandomValues(rawGroupKey);
    html.window.localStorage[_groupKeyStorageKey(group.id)] = base64Encode(
      rawGroupKey,
    );
  }
  await _publishGroupKeyEnvelopes(
    signalingUri: signalingUri,
    session: session,
    groupId: group.id,
    rawGroupKey: rawGroupKey,
  );
}

Future<void> republishStoredGroupKeyIfPresent({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) async {
  final stored = html.window.localStorage[_groupKeyStorageKey(group.id)];
  if (stored == null || stored.isEmpty) return;
  await _publishGroupKeyEnvelopes(
    signalingUri: signalingUri,
    session: session,
    groupId: group.id,
    rawGroupKey: Uint8List.fromList(base64Decode(stored)),
  );
}

Future<String> loadOrFetchGroupKey({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) async {
  final storageKey = _groupKeyStorageKey(group.id);
  final existing = html.window.localStorage[storageKey];
  if (existing != null && existing.isNotEmpty) {
    return existing;
  }

  final identity = await _loadOrCreateIdentityKeyPair(session.username);
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/key-envelope',
    body: {'token': session.token, 'groupId': group.id},
  );
  final encryptedKey = decoded['encryptedKey'];
  if (encryptedKey is! String || encryptedKey.isEmpty) {
    throw StateError('No encrypted group key is available for this account.');
  }

  final privateKey = await _importIdentityPrivateKey(identity.privateKeyBase64);
  final rawGroupKey = await _rsaDecrypt(
    privateKey: privateKey,
    ciphertext: Uint8List.fromList(base64Decode(encryptedKey)),
  );
  final rawGroupKeyBase64 = base64Encode(rawGroupKey);
  html.window.localStorage[storageKey] = rawGroupKeyBase64;
  return rawGroupKeyBase64;
}

Future<void> _publishGroupKeyEnvelopes({
  required Uri signalingUri,
  required AuthSession session,
  required String groupId,
  required Uint8List rawGroupKey,
}) async {
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/member-keys',
    body: {'token': session.token, 'groupId': groupId},
  );
  final members = decoded['members'];
  if (members is! List) {
    throw StateError('Group member keys response was invalid.');
  }

  final envelopes = <Map<String, String>>[];
  for (final memberJson in members.whereType<Map<String, dynamic>>()) {
    final member = AuthenticatedMemberKey.fromJson(memberJson);
    final publicKeyBase64 = member.publicKey;
    if (publicKeyBase64 == null || publicKeyBase64.isEmpty) {
      throw StateError('Missing identity key for ${member.username}.');
    }
    final publicKey = await _importIdentityPublicKey(publicKeyBase64);
    final encryptedKey = await _rsaEncrypt(
      publicKey: publicKey,
      plaintext: rawGroupKey,
    );
    envelopes.add({
      'username': member.username,
      'encryptedKey': base64Encode(encryptedKey),
    });
  }

  await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/key-envelopes/update',
    body: {'token': session.token, 'groupId': groupId, 'envelopes': envelopes},
  );
}

Future<Map<String, dynamic>> _postJson({
  required Uri signalingUri,
  required String path,
  required Map<String, dynamic> body,
}) async {
  late final html.HttpRequest response;
  try {
    response =
        await html.HttpRequest.request(
          _apiUri(signalingUri, path).toString(),
          method: 'POST',
          requestHeaders: {'Content-Type': 'application/json'},
          sendData: jsonEncode(body),
        ).timeout(
          const Duration(seconds: 30),
          onTimeout: () =>
              throw StateError('The server took too long to respond.'),
        );
  } on html.ProgressEvent catch (event) {
    // HttpRequest.request rejects non-2xx responses with an event. Read the
    // response body so API errors remain visible in production web builds.
    final request = event.target;
    if (request is! html.HttpRequest || (request.status ?? 0) == 0) {
      throw StateError(
        'Could not reach the server. Check your connection and server address.',
      );
    }
    response = request;
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(response.responseText ?? '{}');
  } on FormatException {
    throw StateError('The server returned an invalid response.');
  }
  if (response.status == null ||
      response.status! < 200 ||
      response.status! >= 300) {
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      throw StateError(decoded['error'] as String);
    }
    throw StateError('Request failed.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Response was invalid.');
  }
  return decoded;
}

class _IdentityKeyPair {
  const _IdentityKeyPair({
    required this.publicKeyBase64,
    required this.privateKeyBase64,
  });

  final String publicKeyBase64;
  final String privateKeyBase64;
}

Future<_IdentityKeyPair> _loadOrCreateIdentityKeyPair(String username) async {
  final normalized = username.trim().toLowerCase();
  final publicKeyStorage = 'peep:identity-public:$normalized';
  final privateKeyStorage = 'peep:identity-private:$normalized';
  final publicKeyBase64 = html.window.localStorage[publicKeyStorage];
  final privateKeyBase64 = html.window.localStorage[privateKeyStorage];
  if (publicKeyBase64 != null &&
      publicKeyBase64.isNotEmpty &&
      privateKeyBase64 != null &&
      privateKeyBase64.isNotEmpty) {
    return _IdentityKeyPair(
      publicKeyBase64: publicKeyBase64,
      privateKeyBase64: privateKeyBase64,
    );
  }

  final keyPair = await _browserSubtleCrypto
      .callMethod<JSPromise<JSObject>>(
        'generateKey'.toJS,
        {
          'name': 'RSA-OAEP',
          'modulusLength': 2048,
          'publicExponent': Uint8List.fromList([1, 0, 1]).toJS,
          'hash': 'SHA-256',
        }.jsify(),
        true.toJS,
        ['encrypt', 'decrypt'].jsify(),
      )
      .toDart;
  final publicKey = keyPair['publicKey'];
  final privateKey = keyPair['privateKey'];
  if (publicKey == null || privateKey == null) {
    throw StateError('Could not generate identity key pair.');
  }

  final publicBytes = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'exportKey'.toJS,
        'spki'.toJS,
        publicKey,
      )
      .toDart;
  final privateBytes = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'exportKey'.toJS,
        'pkcs8'.toJS,
        privateKey,
      )
      .toDart;
  final generated = _IdentityKeyPair(
    publicKeyBase64: base64Encode(publicBytes.toDart.asUint8List()),
    privateKeyBase64: base64Encode(privateBytes.toDart.asUint8List()),
  );
  html.window.localStorage[publicKeyStorage] = generated.publicKeyBase64;
  html.window.localStorage[privateKeyStorage] = generated.privateKeyBase64;
  return generated;
}

Future<JSAny> _importIdentityPublicKey(String publicKeyBase64) {
  return _browserSubtleCrypto.callMethodVarArgs<JSPromise<JSAny>>(
    'importKey'.toJS,
    [
      'spki'.toJS,
      Uint8List.fromList(base64Decode(publicKeyBase64)).toJS,
      {'name': 'RSA-OAEP', 'hash': 'SHA-256'}.jsify(),
      true.toJS,
      ['encrypt'].jsify(),
    ],
  ).toDart;
}

Future<JSAny> _importIdentityPrivateKey(String privateKeyBase64) {
  return _browserSubtleCrypto.callMethodVarArgs<JSPromise<JSAny>>(
    'importKey'.toJS,
    [
      'pkcs8'.toJS,
      Uint8List.fromList(base64Decode(privateKeyBase64)).toJS,
      {'name': 'RSA-OAEP', 'hash': 'SHA-256'}.jsify(),
      true.toJS,
      ['decrypt'].jsify(),
    ],
  ).toDart;
}

Future<Uint8List> _rsaEncrypt({
  required JSAny publicKey,
  required Uint8List plaintext,
}) async {
  final ciphertext = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'encrypt'.toJS,
        {'name': 'RSA-OAEP'}.jsify(),
        publicKey,
        plaintext.toJS,
      )
      .toDart;
  return ciphertext.toDart.asUint8List();
}

Future<Uint8List> _rsaDecrypt({
  required JSAny privateKey,
  required Uint8List ciphertext,
}) async {
  final plaintext = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'decrypt'.toJS,
        {'name': 'RSA-OAEP'}.jsify(),
        privateKey,
        ciphertext.toJS,
      )
      .toDart;
  return plaintext.toDart.asUint8List();
}

Uri _apiUri(Uri signalingUri, String path) {
  return signalingUri.replace(
    scheme: signalingUri.scheme == 'wss' ? 'https' : 'http',
    path: path,
    query: '',
  );
}

Future<JSObject> _getDisplayMedia(MediaSettings settings) {
  final mediaDevices = html.window.navigator.mediaDevices;
  if (mediaDevices == null) {
    throw StateError('Screen sharing is unavailable in this browser.');
  }
  return JSObject.fromInteropObject(mediaDevices)
      .callMethod<JSPromise<JSObject>>(
        'getDisplayMedia'.toJS,
        {
          'audio': false,
          'video': {...settings.screenConstraints},
        }.jsify(),
      )
      .toDart;
}

List<JSObject> _videoTracksFromJsStream(JSObject stream) {
  return stream.callMethod<JSArray<JSObject>>('getVideoTracks'.toJS).toDart;
}

void _addJsTrackToMediaStream(html.MediaStream stream, JSObject track) {
  JSObject.fromInteropObject(stream).callMethod<JSAny?>('addTrack'.toJS, track);
}

void _onJsTrackEnded(JSObject track, void Function() callback) {
  track.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'ended'.toJS,
    callback.toJS,
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

  factory MailboxSummary.fromJson(Map<String, dynamic> json) {
    return MailboxSummary(
      room: json['room'] as String,
      contactUsername: json['contactUsername'] as String,
      unreadCount: json['unreadCount'] as int,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as int) * 1000,
      ),
    );
  }
}

Future<List<ChatMessage>> loadMessageHistory(String conversationKey) async {
  final raw = await EncryptedStore.instance.read(
    _historyStorageKey(conversationKey),
  );
  if (raw == null || raw.isEmpty) {
    return const [];
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_messageFromJson)
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

Future<void> saveMessageHistory(
  String conversationKey,
  List<ChatMessage> messages,
) async {
  final storageKey = _historyStorageKey(conversationKey);
  var cappedMessages = messages.length > _maxStoredMessages
      ? messages.sublist(messages.length - _maxStoredMessages)
      : List<ChatMessage>.from(messages);

  while (cappedMessages.isNotEmpty) {
    try {
      await EncryptedStore.instance.write(
        storageKey,
        jsonEncode(cappedMessages.map(_messageToJson).toList(growable: false)),
      );
      return;
    } catch (_) {
      final dropCount = cappedMessages.length < 20
          ? 1
          : cappedMessages.length ~/ 4;
      cappedMessages = cappedMessages.sublist(dropCount);
    }
  }

  await EncryptedStore.instance.delete(storageKey);
}

Future<List<StoredConversation>> listStoredDirectConversations(
  String username,
) async {
  final normalizedUsername = username.trim().toLowerCase();
  final conversations = <StoredConversation>[];
  final records = await EncryptedStore.instance.readAll();
  for (final storageKey in records.keys) {
    if (!storageKey.startsWith(_historyStoragePrefix)) {
      continue;
    }

    final conversationKey = storageKey.substring(_historyStoragePrefix.length);
    final parts = conversationKey.split(':');
    if (parts.length != 3 || parts.first != 'dm') {
      continue;
    }
    final first = parts[1];
    final second = parts[2];
    if (first != normalizedUsername && second != normalizedUsername) {
      continue;
    }

    final messages = await loadMessageHistory(conversationKey);
    if (messages.isEmpty) {
      continue;
    }
    final lastMessage = messages.last;
    conversations.add(
      StoredConversation(
        conversationKey: conversationKey,
        contactUsername: first == normalizedUsername ? second : first,
        lastText: lastMessage.attachment == null
            ? lastMessage.text
            : lastMessage.attachment!.name,
        updatedAt: lastMessage.sentAt,
      ),
    );
  }

  conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return conversations;
}

Future<html.File?> _pickWebAttachmentFile() {
  final input = html.FileUploadInputElement()
    ..accept = 'audio/*,video/*'
    ..multiple = false;
  final completer = Completer<html.File?>();
  late StreamSubscription<html.Event> changeSubscription;
  late StreamSubscription<html.Event> blurSubscription;
  late StreamSubscription<html.Event> focusSubscription;
  Timer? focusFallback;
  var windowBlurred = false;
  late void Function(html.Event) onCancel;

  void finish(html.File? file) {
    if (completer.isCompleted) return;
    focusFallback?.cancel();
    input.removeEventListener('cancel', onCancel);
    unawaited(changeSubscription.cancel());
    unawaited(blurSubscription.cancel());
    unawaited(focusSubscription.cancel());
    completer.complete(file);
  }

  onCancel = (html.Event _) => finish(null);
  changeSubscription = input.onChange.listen((_) {
    final files = input.files;
    finish(files == null || files.isEmpty ? null : files.first);
  });
  blurSubscription = html.window.onBlur.listen((_) => windowBlurred = true);
  focusSubscription = html.window.onFocus.listen((_) {
    if (!windowBlurred) return;
    focusFallback?.cancel();
    focusFallback = Timer(const Duration(milliseconds: 750), () {
      final files = input.files;
      finish(files == null || files.isEmpty ? null : files.first);
    });
  });
  input.addEventListener('cancel', onCancel);
  input.click();
  return completer.future;
}

Future<Uint8List> _readWebAttachmentBytes(html.File file) {
  final completer = Completer<Uint8List>();
  final reader = html.FileReader();
  late StreamSubscription<html.ProgressEvent> loadSubscription;
  late StreamSubscription<html.ProgressEvent> errorSubscription;
  late StreamSubscription<html.ProgressEvent> abortSubscription;

  void cleanup() {
    unawaited(loadSubscription.cancel());
    unawaited(errorSubscription.cancel());
    unawaited(abortSubscription.cancel());
  }

  loadSubscription = reader.onLoad.listen((_) {
    if (completer.isCompleted) return;
    final result = reader.result;
    if (result is Uint8List) {
      completer.complete(result);
    } else if (result is ByteBuffer) {
      completer.complete(result.asUint8List());
    } else {
      completer.completeError(
        StateError('Could not read the selected attachment.'),
      );
    }
    cleanup();
  });
  errorSubscription = reader.onError.listen((_) {
    if (completer.isCompleted) return;
    completer.completeError(
      StateError('Could not read the selected attachment.'),
    );
    cleanup();
  });
  abortSubscription = reader.onAbort.listen((_) {
    if (completer.isCompleted) return;
    completer.completeError(
      StateError('Reading the selected attachment was canceled.'),
    );
    cleanup();
  });
  reader.readAsArrayBuffer(file);
  return completer.future;
}

class _RemoteMediaView {
  _RemoteMediaView({
    required this.title,
    required this.viewType,
    required this.stream,
    required this.video,
  });

  final String title;
  final String viewType;
  final html.MediaStream stream;
  final html.VideoElement video;
}

class GroupClient {
  MediaSettings _mediaSettings = MediaSettings.defaults;
  Future<void> setMediaSettings(MediaSettings settings) async {
    _mediaSettings = settings;
    final connection = _publisherConnection;
    if (_screenShareEnabled && _localStream != null) {
      await applyWebScreenConstraints(_localStream!, settings);
    }
    if (connection != null) {
      await applyWebSenderLimits(
        connection,
        settings,
        screenSharing: _screenShareEnabled,
        screenPaused: _screenSharePaused,
      );
    }
  }

  Future<void> _applySenderLimits(html.RtcPeerConnection connection) async {
    try {
      await applyWebSenderLimits(
        connection,
        _mediaSettings,
        screenSharing: _screenShareEnabled,
        screenPaused: _screenSharePaused,
      );
    } catch (error) {
      onLog('Could not apply media limits: $error');
    }
  }

  GroupClient({
    required this.onStatus,
    required this.onMessage,
    required this.onLog,
    required this.onMediaChanged,
  }) {
    _registerVideoViews();
  }

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;
  final void Function() onMediaChanged;

  html.WebSocket? _socket;
  html.RtcPeerConnection? _publisherConnection;
  html.RtcPeerConnection? _subscriberConnection;
  html.MediaStream? _localStream;
  late final html.VideoElement _localVideo;
  late final String _localVideoViewType;
  final Map<String, _RemoteMediaView> _remoteViews = {};
  JSAny? _groupAesKey;
  Uri? _conferenceSignalingUri;
  String? _conferenceToken;
  String? _conferenceGroupId;
  Timer? _conferenceRefreshTimer;
  bool _closed = false;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  bool _screenShareEnabled = false;
  bool _screenSharePaused = false;
  int _screenCaptureGeneration = 0;
  bool _conferenceRefreshQueued = false;
  bool _conferenceRefreshInProgress = false;
  int _remoteParticipantCount = 1;
  int _conferenceGeneration = 0;
  CallState _callState = CallState.idle;
  final Map<String, IncomingAttachmentPayload> _incomingAttachments = {};
  static int _nextViewId = 0;
  static int _nextRemoteViewId = 0;
  static int _nextAttachmentId = 0;
  static const int _attachmentChunkSize = attachmentChunkChars;

  bool get canSend => _socket?.readyState == html.WebSocket.OPEN;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
  bool get screenShareEnabled => _screenShareEnabled;
  bool get screenSharePaused => _screenShareEnabled && _screenSharePaused;
  CallState get callState => _callState;
  bool get callActive => _callState != CallState.idle;
  String get localVideoViewType => _localVideoViewType;
  String? get remoteVideoViewType =>
      _remoteViews.isEmpty ? null : _remoteViews.values.first.viewType;
  List<MediaView> get remoteVideoViews => _remoteViews.values
      .map(
        (view) => MediaView(
          title: view.title,
          viewType: _hasLiveVideo(view.stream) ? view.viewType : null,
        ),
      )
      .toList(growable: false);

  void _registerVideoViews() {
    final id = _nextViewId++;
    _localVideoViewType = 'peep-group-local-video-$id';
    _localVideo = _createVideoElement(muted: true);

    ui_web.platformViewRegistry.registerViewFactory(
      _localVideoViewType,
      (int viewId) => _localVideo,
    );
  }

  html.VideoElement _createVideoElement({required bool muted}) {
    final video = html.VideoElement()
      ..autoplay = true
      ..muted = muted
      ..controls = false
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.pointerEvents = 'none'
      ..style.backgroundColor = '#111827';
    video.onCanPlay.listen((_) => _resumeVideo(video));
    return video;
  }

  Future<void> connect({
    required Uri signalingUri,
    required String token,
    required String groupId,
    required String groupKeyBase64,
    int memberCount = 2,
  }) async {
    await disconnect();
    _remoteParticipantCount = max(1, memberCount - 1);
    _closed = false;
    _incomingAttachments.clear();
    _groupAesKey = await _importAesGcmKey(groupKeyBase64);
    onStatus(PeerStatus.signaling);
    final url = signalingUri.replace(
      queryParameters: {
        ...signalingUri.queryParameters,
        'token': token,
        'group': groupId,
      },
    );
    await _connectSocket(url);
  }

  void send(String text) {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      onLog('Group socket is not open.');
      return;
    }

    unawaited(_sendEncrypted(socket, {'kind': 'group-chat', 'body': text}));
    onMessage(ChatMessage(text: text, isLocal: true, sentAt: DateTime.now()));
  }

  Future<void> pickAndSendAttachment() async {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      onLog('Open the group chat before sending an attachment.');
      return;
    }
    final file = await _pickWebAttachmentFile();
    if (file == null) return;
    validateAttachmentSize(file.size);
    final bytes = await _readWebAttachmentBytes(file);
    final mimeType = resolveAttachmentMimeType(
      name: file.name,
      bytes: bytes,
      fallback: file.type,
    );
    validateAttachmentMetadata(
      name: file.name,
      mimeType: mimeType,
      size: bytes.length,
    );
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final attachment = _createGroupAttachmentData(
      name: file.name,
      mimeType: mimeType,
      size: bytes.length,
      dataUrl: dataUrl,
    );
    onMessage(
      ChatMessage(
        text: file.name,
        isLocal: true,
        sentAt: DateTime.now(),
        attachment: attachment,
      ),
    );
    await _sendGroupAttachment(attachment: attachment);
  }

  Future<void> startConference({
    required Uri signalingUri,
    required String token,
    required String groupId,
  }) async {
    if (_socket?.readyState != html.WebSocket.OPEN) {
      onLog('Open the group chat before starting a group call.');
      return;
    }
    if (_callState != CallState.idle) {
      return;
    }

    _conferenceSignalingUri = signalingUri;
    _conferenceToken = token;
    _conferenceGroupId = groupId;
    final generation = ++_conferenceGeneration;
    _callState = CallState.outgoing;
    onMediaChanged();

    try {
      final conference = await _postJson(
        signalingUri: signalingUri,
        path: '/api/groups/conference/start',
        body: {'token': token, 'groupId': groupId},
      );
      final mode = conference['mode'];
      if (generation != _conferenceGeneration || _closed) return;
      if (mode is String) {
        onLog('Group conference mode: $mode.');
      }
      await _ensureLocalMedia(audio: true, video: false);
      if (generation != _conferenceGeneration || _closed) return;
      await _joinPublisher();
      if (generation != _conferenceGeneration || _closed) return;
      await _joinSubscriber();
      if (generation != _conferenceGeneration || _closed) return;
      _publishConferenceRefresh();
      _callState = CallState.active;
      onLog('Group call started.');
      onMediaChanged();
    } catch (error) {
      if (generation != _conferenceGeneration || _closed) return;
      await _stopConferenceMedia(notifyServer: true);
      onLog('Could not start group call: $error');
    }
  }

  Future<void> endConference() async {
    if (_callState == CallState.idle) {
      return;
    }

    await _stopConferenceMedia(notifyServer: true);
    onLog('Group call ended.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    _screenCaptureGeneration++;
    if (_callState != CallState.active) {
      onLog('Start a group call before turning on video.');
      return;
    }

    if (enabled &&
        (_screenShareEnabled ||
            _localStream?.getVideoTracks().isEmpty != false)) {
      try {
        if (_screenShareEnabled) {
          _stopLocalVideoTracks();
        }
        _screenShareEnabled = false;
        await _ensureLocalMedia(audio: false, video: true);
        await _joinPublisher();
        _publishConferenceRefresh();
      } catch (error) {
        _cameraEnabled = false;
        onLog('Could not start camera: $error');
        onMediaChanged();
      }
      return;
    }

    if (!enabled) {
      final stopped = _stopLocalVideoTracks();
      _cameraEnabled = false;
      _screenShareEnabled = false;
      if (stopped) {
        await _joinPublisher();
        _publishConferenceRefresh();
      }
      onLog('Camera turned off.');
      onMediaChanged();
      return;
    }

    _cameraEnabled = enabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <html.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Camera enabled.' : 'Camera disabled.');
    onMediaChanged();
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a group call before changing microphone state.');
      return;
    }

    if (enabled && _localStream?.getAudioTracks().isEmpty != false) {
      try {
        await _ensureLocalMedia(audio: true, video: false);
        await _joinPublisher();
        _publishConferenceRefresh();
      } catch (error) {
        _microphoneEnabled = false;
        onLog('Could not start microphone: $error');
        onMediaChanged();
      }
      return;
    }

    _microphoneEnabled = enabled;
    for (final track
        in _localStream?.getAudioTracks() ?? <html.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Microphone enabled.' : 'Microphone muted.');
    onMediaChanged();
  }

  Future<void> setScreenSharePaused(bool paused) async {
    if (!_screenShareEnabled || _callState != CallState.active) return;
    final connection = _publisherConnection;
    if (connection == null) return;
    try {
      await applyWebSenderLimits(
        connection,
        _mediaSettings,
        screenSharing: true,
        screenPaused: paused,
      );
      _screenSharePaused = paused;
      for (final track
          in _localStream?.getVideoTracks() ?? <html.MediaStreamTrack>[]) {
        track.enabled = !paused;
      }
      onLog(paused ? 'Screen sharing paused.' : 'Screen sharing resumed.');
      onMediaChanged();
    } catch (error) {
      onLog('Could not update screen sharing: $error');
    }
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a group call before sharing your screen.');
      return;
    }
    final generation = ++_screenCaptureGeneration;
    if (!enabled) {
      final stopped = _stopLocalVideoTracks();
      _screenShareEnabled = false;
      _cameraEnabled = false;
      if (stopped) {
        await _joinPublisher();
        _publishConferenceRefresh();
      }
      onLog('Screen sharing stopped.');
      onMediaChanged();
      return;
    }
    try {
      final screen = await _getDisplayMedia(_mediaSettings);
      final tracks = _videoTracksFromJsStream(screen);
      if (generation != _screenCaptureGeneration ||
          _closed ||
          _callState != CallState.active) {
        for (final track in tracks) {
          track.callMethod<JSAny?>('stop'.toJS);
        }
        return;
      }
      if (tracks.isEmpty) {
        throw StateError('No screen video track was selected.');
      }
      final paused = screenSharePaused;
      _stopLocalVideoTracks();
      _localStream ??= html.MediaStream();
      for (final track in tracks) {
        _addJsTrackToMediaStream(_localStream!, track);
        track['enabled'] = (!paused).toJS;
        _onJsTrackEnded(track, () {
          if (_screenShareEnabled &&
              _localStream?.getVideoTracks().any(
                    (current) =>
                        identical(JSObject.fromInteropObject(current), track),
                  ) ==
                  true) {
            unawaited(setScreenShareEnabled(false));
          }
        });
      }
      _setVideoStream(_localVideo, _localStream);
      _screenShareEnabled = true;
      _screenSharePaused = paused;
      _cameraEnabled = false;
      await _joinPublisher();
      _publishConferenceRefresh();
      onLog('Screen sharing started.');
      onMediaChanged();
    } catch (error) {
      if (generation != _screenCaptureGeneration) return;
      onLog('Could not share screen: $error');
      onMediaChanged();
    }
  }

  Future<void> disconnect() async {
    _closed = true;
    await _stopConferenceMedia(notifyServer: true);
    _socket?.close();
    _socket = null;
    _groupAesKey = null;
    _incomingAttachments.clear();
    onStatus(PeerStatus.disconnected);
  }

  Future<void> _sendEncrypted(
    html.WebSocket socket,
    Map<String, dynamic> payload,
  ) async {
    final key = _groupAesKey;
    if (key == null) {
      onLog('Group key is not ready.');
      return;
    }

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final iv = Uint8List(12);
    html.window.crypto!.getRandomValues(iv);
    final ciphertext = await _aesGcmEncrypt(
      key: key,
      plaintext: plaintext,
      iv: iv,
    );
    socket.sendString(
      jsonEncode({
        'type': 'group-e2ee',
        'payload': {
          'iv': base64Encode(iv),
          'ciphertext': base64Encode(ciphertext),
        },
      }),
    );
  }

  Future<void> _connectSocket(Uri uri) {
    final completer = Completer<void>();
    final socket = html.WebSocket(uri.toString());
    _socket = socket;

    socket.onOpen.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      onLog('Group signaling connected.');
    });

    socket.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Could not connect to group.'));
      }
      onStatus(PeerStatus.failed);
      onLog('Group socket error.');
    });

    socket.onClose.listen((_) {
      if (!_closed) {
        onStatus(PeerStatus.disconnected);
      }
      onLog('Group signaling disconnected.');
    });

    socket.onMessage.listen((event) {
      final data = event.data;
      if (data is String) {
        _handleSignal(data);
      }
    });

    return completer.future.timeout(const Duration(seconds: 8));
  }

  void _handleSignal(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      switch (decoded['type']) {
        case 'welcome':
          onStatus(PeerStatus.connected);
          onLog('Joined group.');
          break;
        case 'presence':
          onLog('Group peer ${decoded['peer']} ${decoded['event']}.');
          break;
        case 'group-chat':
          final body = decoded['body'];
          final from = decoded['from'];
          if (body is String) {
            onMessage(
              ChatMessage(
                text: body,
                isLocal: false,
                sentAt: DateTime.now(),
                sender: from is String ? from : null,
              ),
            );
          }
          break;
        case 'group-e2ee':
          unawaited(_handleEncryptedGroupPayload(decoded));
          break;
        case 'conference-refresh':
          if (_callState == CallState.active) {
            _scheduleConferenceRefresh();
          }
          break;
        case 'error':
          onStatus(PeerStatus.failed);
          onLog('${decoded['message'] ?? 'Group signaling error.'}');
          break;
      }
    } catch (error) {
      onStatus(PeerStatus.failed);
      onLog('Group signal handling failed: $error');
    }
  }

  Future<void> _handleEncryptedGroupPayload(
    Map<String, dynamic> decoded,
  ) async {
    final key = _groupAesKey;
    final payload = decoded['payload'];
    if (key == null || payload is! Map<String, dynamic>) {
      return;
    }

    final iv = payload['iv'];
    final ciphertext = payload['ciphertext'];
    if (iv is! String || ciphertext is! String) {
      return;
    }

    try {
      final plaintext = await _aesGcmDecrypt(
        key: key,
        ciphertext: Uint8List.fromList(base64Decode(ciphertext)),
        iv: Uint8List.fromList(base64Decode(iv)),
      );
      final appPayload = jsonDecode(utf8.decode(plaintext));
      if (appPayload is! Map<String, dynamic>) {
        return;
      }
      final from = decoded['from'];
      final sender = from is String ? from : null;
      switch (appPayload['kind']) {
        case 'group-chat':
          if (appPayload['body'] is String) {
            onMessage(
              ChatMessage(
                text: appPayload['body'] as String,
                isLocal: false,
                sentAt: DateTime.now(),
                sender: sender,
              ),
            );
          }
          break;
        case 'group-attachment-start':
          _handleGroupAttachmentStart(appPayload);
          break;
        case 'group-attachment-chunk':
          _handleGroupAttachmentChunk(appPayload);
          break;
        case 'group-attachment-end':
          _handleGroupAttachmentEnd(appPayload, sender);
          break;
      }
    } catch (error) {
      onLog('Could not decrypt group message: $error');
    }
  }

  Future<void> _sendGroupAttachment({
    required AttachmentData attachment,
  }) async {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      throw StateError(
        'Group chat disconnected before the attachment was sent.',
      );
    }
    validateAttachmentMetadata(
      name: attachment.name,
      mimeType: attachment.mimeType,
      size: attachment.size,
    );
    if (!isValidAttachmentDataUrl(
      dataUrl: attachment.dataUrl,
      mimeType: attachment.mimeType,
      size: attachment.size,
    )) {
      throw StateError('Could not prepare the selected attachment.');
    }
    final id =
        'group-attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}';
    await _sendEncrypted(socket, {
      'kind': 'group-attachment-start',
      'id': id,
      'name': attachment.name,
      'mimeType': attachment.mimeType,
      'size': attachment.size,
    });
    for (
      var offset = 0;
      offset < attachment.dataUrl.length;
      offset += _attachmentChunkSize
    ) {
      final end = min(offset + _attachmentChunkSize, attachment.dataUrl.length);
      await _sendEncrypted(socket, {
        'kind': 'group-attachment-chunk',
        'id': id,
        'data': attachment.dataUrl.substring(offset, end),
      });
      while ((socket.bufferedAmount ?? 0) > 512 * 1024) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    await _sendEncrypted(socket, {'kind': 'group-attachment-end', 'id': id});
    onLog('Group attachment sent: ${attachment.name}.');
  }

  void _handleGroupAttachmentStart(Map<String, dynamic> payload) {
    final id = payload['id'];
    final name = payload['name'];
    final mimeType = payload['mimeType'];
    final size = payload['size'];
    if (id is! String ||
        name is! String ||
        mimeType is! String ||
        size is! int) {
      return;
    }
    final normalizedMimeType = normalizeAttachmentMimeType(mimeType);
    if (id.isEmpty || id.length > 128) return;
    try {
      validateAttachmentMetadata(
        name: name,
        mimeType: normalizedMimeType,
        size: size,
      );
    } on StateError {
      onLog('Discarded an invalid or oversized group attachment.');
      return;
    }
    _incomingAttachments[id] = IncomingAttachmentPayload(
      name: name,
      mimeType: normalizedMimeType,
      size: size,
    );
    onLog('Receiving group attachment: $name.');
  }

  void _handleGroupAttachmentChunk(Map<String, dynamic> payload) {
    final id = payload['id'];
    final data = payload['data'];
    if (id is String && data is String) {
      final incoming = _incomingAttachments[id];
      if (incoming != null && !incoming.appendChunk(data)) {
        _incomingAttachments.remove(id);
        onLog('Discarded an invalid group attachment chunk.');
      }
    }
  }

  void _handleGroupAttachmentEnd(Map<String, dynamic> payload, String? sender) {
    final id = payload['id'];
    if (id is! String) return;
    final incoming = _incomingAttachments.remove(id);
    if (incoming == null) return;
    final dataUrl = incoming.takeValidatedDataUrl();
    if (dataUrl == null) {
      onLog('Discarded an incomplete or invalid group attachment.');
      return;
    }
    final attachment = _createGroupAttachmentData(
      name: incoming.name,
      mimeType: incoming.mimeType,
      size: incoming.size,
      dataUrl: dataUrl,
    );
    onMessage(
      ChatMessage(
        text: incoming.name,
        isLocal: false,
        sentAt: DateTime.now(),
        sender: sender,
        attachment: attachment,
      ),
    );
    onLog('Group attachment received: ${incoming.name}.');
  }

  AttachmentData _createGroupAttachmentData({
    required String name,
    required String mimeType,
    required int size,
    required String dataUrl,
  }) {
    final isVideo = mimeType.startsWith('video/');
    String? viewType;
    if (isVideo || mimeType.startsWith('audio/')) {
      viewType =
          'peep-group-attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}';
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
        if (isVideo) {
          return html.VideoElement()
            ..src = dataUrl
            ..controls = true
            ..preload = 'metadata'
            ..setAttribute('playsinline', 'true')
            ..style.width = '100%'
            ..style.height = '100%'
            ..style.objectFit = 'contain';
        }
        return html.AudioElement()
          ..src = dataUrl
          ..controls = true
          ..preload = 'metadata'
          ..style.width = '100%'
          ..style.height = '100%';
      });
    }
    return AttachmentData(
      name: name,
      mimeType: mimeType,
      size: size,
      dataUrl: dataUrl,
      viewType: viewType,
    );
  }

  Future<void> _ensureLocalMedia({
    required bool audio,
    required bool video,
  }) async {
    final generation = _conferenceGeneration;
    final needsAudio = audio && _localStream?.getAudioTracks().isEmpty != false;
    final needsVideo = video && _localStream?.getVideoTracks().isEmpty != false;
    if (!needsAudio && !needsVideo) {
      _updateLocalMediaState();
      return;
    }

    onLog(
      'Requesting ${needsVideo ? 'camera' : ''}${needsVideo && needsAudio ? ' and ' : ''}${needsAudio ? 'microphone' : ''}.',
    );
    final stream = await html.window.navigator.mediaDevices!.getUserMedia({
      'audio': needsAudio ? _mediaSettings.audioConstraints : false,
      'video': needsVideo ? _mediaSettings.videoConstraints : false,
    });
    if (generation != _conferenceGeneration || _closed) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }

    _localStream ??= html.MediaStream();
    for (final track in stream.getTracks()) {
      _localStream!.addTrack(track);
    }
    _setVideoStream(_localVideo, _localStream);
    _updateLocalMediaState();
    onLog(
      '${needsVideo ? 'Camera' : ''}${needsVideo && needsAudio ? ' and ' : ''}${needsAudio ? 'microphone' : ''} ready.',
    );
    onMediaChanged();
  }

  void _updateLocalMediaState() {
    _cameraEnabled =
        _localStream?.getVideoTracks().any((track) => track.enabled == true) ??
        false;
    _microphoneEnabled =
        _localStream?.getAudioTracks().any((track) => track.enabled == true) ??
        false;
  }

  bool _stopLocalVideoTracks() {
    _screenSharePaused = false;
    final stream = _localStream;
    if (stream == null) {
      _setVideoStream(_localVideo, null);
      return false;
    }

    final videoTracks = List<html.MediaStreamTrack>.from(
      stream.getVideoTracks(),
    );
    if (videoTracks.isEmpty) {
      return false;
    }

    for (final track in videoTracks) {
      track.stop();
      stream.removeTrack(track);
    }
    _setVideoStream(_localVideo, stream.getTracks().isEmpty ? null : stream);
    return true;
  }

  Future<void> _joinPublisher() async {
    final signalingUri = _conferenceSignalingUri;
    final token = _conferenceToken;
    final groupId = _conferenceGroupId;
    if (signalingUri == null || token == null || groupId == null) {
      throw StateError('Group conference is not initialized.');
    }

    _publisherConnection?.close();
    _publisherConnection = _createSfuPeerConnection();
    _wireMediaConnection(_publisherConnection!, label: 'publisher');

    for (final track
        in _localStream?.getTracks() ?? <html.MediaStreamTrack>[]) {
      _publisherConnection!.addTrack(track, _localStream!);
    }

    await _negotiateSfu(
      role: 'publisher',
      peerConnection: _publisherConnection!,
      signalingUri: signalingUri,
      token: token,
      groupId: groupId,
    );
    onStatus(PeerStatus.connected);
  }

  Future<void> _joinSubscriber() async {
    final signalingUri = _conferenceSignalingUri;
    final token = _conferenceToken;
    final groupId = _conferenceGroupId;
    if (signalingUri == null || token == null || groupId == null) {
      throw StateError('Group conference is not initialized.');
    }

    _subscriberConnection?.close();
    _clearRemoteViews();
    _subscriberConnection = _createSfuPeerConnection();
    _wireMediaConnection(_subscriberConnection!, label: 'subscriber');
    for (var i = 0; i < _remoteParticipantCount; i++) {
      _addReceiveOnlyTransceiver(_subscriberConnection!, 'audio');
      _addReceiveOnlyTransceiver(_subscriberConnection!, 'video');
    }

    await _negotiateSfu(
      role: 'subscriber',
      peerConnection: _subscriberConnection!,
      signalingUri: signalingUri,
      token: token,
      groupId: groupId,
    );
    onStatus(PeerStatus.connected);
  }

  html.RtcPeerConnection _createSfuPeerConnection() {
    return html.RtcPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
  }

  Future<void> _negotiateSfu({
    required String role,
    required html.RtcPeerConnection peerConnection,
    required Uri signalingUri,
    required String token,
    required String groupId,
  }) async {
    await applyWebCodecPreferences(peerConnection, _mediaSettings, onLog);
    final offer = await _createMediaDescription(peerConnection, 'createOffer');
    await _setMediaLocalDescription(peerConnection, offer);
    await _applySenderLimits(peerConnection);
    await _waitForIceGatheringComplete(peerConnection);
    final gatheredOffer = _mediaLocalDescription(peerConnection);
    final decoded = await _postJson(
      signalingUri: signalingUri,
      path: '/api/groups/sfu/join',
      body: {
        'token': token,
        'groupId': groupId,
        'role': role,
        'offer': gatheredOffer,
      },
    );
    final answer = decoded['answer'];
    if (answer is! Map<String, dynamic>) {
      throw StateError('SFU answer was invalid.');
    }
    await _setMediaRemoteDescription(peerConnection, {
      'type': answer['type'],
      'sdp': answer['sdp'],
    });
    await _applySenderLimits(peerConnection);
  }

  void _wireMediaConnection(
    html.RtcPeerConnection mediaConnection, {
    required String label,
  }) {
    mediaConnection.onConnectionStateChange.listen((_) {
      if (_closed ||
          !identical(mediaConnection, _publisherConnection) &&
              !identical(mediaConnection, _subscriberConnection)) {
        return;
      }
      switch (mediaConnection.connectionState) {
        case 'connected':
          onStatus(PeerStatus.connected);
          break;
        case 'connecting':
          onStatus(PeerStatus.connecting);
          break;
        case 'failed':
          onStatus(PeerStatus.failed);
          break;
      }
    });

    mediaConnection.onIceConnectionStateChange.listen((_) {
      onLog(
        'Group call $label ICE state: ${mediaConnection.iceConnectionState ?? 'unknown'}',
      );
    });

    mediaConnection.onTrack.listen((event) {
      if (label != 'subscriber' ||
          !identical(mediaConnection, _subscriberConnection)) {
        return;
      }
      final track = event.track;
      if (track == null) {
        return;
      }
      // Empty SFU answers can expose streamless placeholder tracks. They do
      // not represent a participant and must not produce a blank tile.
      if (event.streams?.isNotEmpty != true) return;
      final stream = event.streams!.first;
      if (track.kind == 'video') {
        void refresh(_) {
          if (identical(mediaConnection, _subscriberConnection)) {
            onMediaChanged();
          }
        }

        track.onMute.listen(refresh);
        track.onUnmute.listen(refresh);
        track.onEnded.listen(refresh);
      }
      if (stream.id?.startsWith('sfu-$_conferenceGroupId-') != true) return;
      final remoteView = _remoteViewForStream(stream);
      _setVideoStream(remoteView.video, remoteView.stream);
      onLog('Group remote ${track.kind ?? 'media'} track received.');
      onMediaChanged();
    });
  }

  _RemoteMediaView _remoteViewForStream(html.MediaStream stream) {
    final rawStreamId = stream.id;
    final streamId = rawStreamId == null || rawStreamId.isEmpty
        ? 'remote-${_nextRemoteViewId++}'
        : rawStreamId;
    final existing = _remoteViews[streamId];
    if (existing != null) {
      return existing;
    }

    final viewType = 'peep-group-remote-video-${_nextRemoteViewId++}';
    final video = _createVideoElement(muted: false);
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId) => video,
    );
    final remoteView = _RemoteMediaView(
      title: _remoteTitleForStream(streamId),
      viewType: viewType,
      stream: stream,
      video: video,
    );
    _remoteViews[streamId] = remoteView;
    return remoteView;
  }

  String _remoteTitleForStream(String streamId) {
    final prefix = 'sfu-$_conferenceGroupId-';
    if (streamId.startsWith(prefix)) return streamId.substring(prefix.length);
    if (streamId.startsWith('sfu-')) {
      final separator = streamId.lastIndexOf('-');
      if (separator > 0 && separator < streamId.length - 1) {
        return streamId.substring(separator + 1);
      }
    }
    return 'Remote';
  }

  void _clearRemoteViews() {
    for (final remoteView in _remoteViews.values) {
      remoteView.stream.getTracks().forEach((track) => track.stop());
      _setVideoStream(remoteView.video, null);
    }
    _remoteViews.clear();
  }

  void _addReceiveOnlyTransceiver(
    html.RtcPeerConnection peerConnection,
    String kind,
  ) {
    final mediaConnection = JSObject.fromInteropObject(peerConnection);
    mediaConnection.callMethod<JSAny?>(
      'addTransceiver'.toJS,
      kind.toJS,
      {'direction': 'recvonly'}.jsify(),
    );
  }

  Future<Map<String, dynamic>> _createMediaDescription(
    html.RtcPeerConnection peerConnection,
    String method,
  ) async {
    final mediaConnection = JSObject.fromInteropObject(peerConnection);
    final description = await mediaConnection
        .callMethod<JSPromise<JSObject>>(method.toJS)
        .toDart;

    return _descriptionFromJs(description);
  }

  Future<void> _setMediaLocalDescription(
    html.RtcPeerConnection peerConnection,
    Map<String, dynamic> description,
  ) {
    final mediaConnection = JSObject.fromInteropObject(peerConnection);
    return mediaConnection
        .callMethod<JSPromise<JSAny?>>(
          'setLocalDescription'.toJS,
          description.jsify(),
        )
        .toDart;
  }

  Future<void> _setMediaRemoteDescription(
    html.RtcPeerConnection peerConnection,
    Map<String, dynamic> description,
  ) {
    final mediaConnection = JSObject.fromInteropObject(peerConnection);
    return mediaConnection
        .callMethod<JSPromise<JSAny?>>(
          'setRemoteDescription'.toJS,
          description.jsify(),
        )
        .toDart;
  }

  Map<String, dynamic> _mediaLocalDescription(
    html.RtcPeerConnection peerConnection,
  ) {
    final mediaConnection = JSObject.fromInteropObject(peerConnection);
    final description = mediaConnection['localDescription'] as JSObject?;
    if (description == null) {
      throw StateError('Local SFU offer was not generated.');
    }
    return _descriptionFromJs(description);
  }

  Map<String, dynamic> _descriptionFromJs(JSObject description) {
    return {
      'type': (description['type'] as JSString?)?.toDart,
      'sdp': (description['sdp'] as JSString?)?.toDart,
    };
  }

  Future<void> _waitForIceGatheringComplete(
    html.RtcPeerConnection mediaConnection,
  ) async {
    if (mediaConnection.iceGatheringState == 'complete') {
      return;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (mediaConnection.iceGatheringState != 'complete' &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _publishConferenceRefresh() {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      return;
    }
    socket.sendString(jsonEncode({'type': 'conference-refresh'}));
  }

  void _scheduleConferenceRefresh() {
    if (_conferenceRefreshQueued) {
      return;
    }

    _conferenceRefreshQueued = true;
    _conferenceRefreshTimer?.cancel();
    _conferenceRefreshTimer = Timer(const Duration(milliseconds: 900), () {
      _conferenceRefreshQueued = false;
      if (_callState != CallState.active) {
        return;
      }
      unawaited(_refreshConference());
    });
  }

  Future<void> _refreshConference() async {
    if (_conferenceRefreshInProgress) {
      _scheduleConferenceRefresh();
      return;
    }
    _conferenceRefreshInProgress = true;
    try {
      onLog('Refreshing group call participants.');
      await _joinSubscriber();
      onMediaChanged();
    } catch (error) {
      onLog('Could not refresh group call: $error');
    } finally {
      _conferenceRefreshInProgress = false;
    }
  }

  Future<void> _stopConferenceMedia({required bool notifyServer}) async {
    _conferenceGeneration++;
    _screenCaptureGeneration++;
    _screenSharePaused = false;
    _conferenceRefreshTimer?.cancel();
    _conferenceRefreshTimer = null;
    _conferenceRefreshQueued = false;
    _publisherConnection?.close();
    _subscriberConnection?.close();
    _publisherConnection = null;
    _subscriberConnection = null;
    _localStream?.getTracks().forEach((track) => track.stop());
    _clearRemoteViews();
    _localStream = null;
    _setVideoStream(_localVideo, null);
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    _callState = CallState.idle;

    final signalingUri = _conferenceSignalingUri;
    final token = _conferenceToken;
    final groupId = _conferenceGroupId;
    if (notifyServer &&
        signalingUri != null &&
        token != null &&
        groupId != null) {
      try {
        await _postJson(
          signalingUri: signalingUri,
          path: '/api/groups/sfu/leave',
          body: {'token': token, 'groupId': groupId, 'role': 'publisher'},
        );
        await _postJson(
          signalingUri: signalingUri,
          path: '/api/groups/sfu/leave',
          body: {'token': token, 'groupId': groupId, 'role': 'subscriber'},
        );
        await _postJson(
          signalingUri: signalingUri,
          path: '/api/groups/conference/end',
          body: {'token': token, 'groupId': groupId},
        );
      } catch (error) {
        onLog('Could not close group call session: $error');
      }
      _publishConferenceRefresh();
    }

    _conferenceSignalingUri = null;
    _conferenceToken = null;
    _conferenceGroupId = null;
    onMediaChanged();
  }
}

class PeerClient {
  MediaSettings _mediaSettings = MediaSettings.defaults;
  Future<void> setMediaSettings(MediaSettings settings) async {
    _mediaSettings = settings;
    final connection = _peerConnection;
    if (_screenShareEnabled && _localStream != null) {
      await applyWebScreenConstraints(_localStream!, settings);
    }
    if (connection != null) {
      await applyWebSenderLimits(
        connection,
        settings,
        screenSharing: _screenShareEnabled,
        screenPaused: _screenSharePaused,
      );
    }
  }

  Future<void> _applySenderLimits(html.RtcPeerConnection connection) async {
    try {
      await applyWebSenderLimits(
        connection,
        _mediaSettings,
        screenSharing: _screenShareEnabled,
        screenPaused: _screenSharePaused,
      );
    } catch (error) {
      onLog('Could not apply media limits: $error');
    }
  }

  PeerClient({
    required this.onStatus,
    required this.onMessage,
    required this.onLog,
    required this.onMediaChanged,
  }) {
    _registerVideoViews();
  }

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;
  final void Function() onMediaChanged;

  html.RtcPeerConnection? _peerConnection;
  html.RtcDataChannel? _dataChannel;
  html.WebSocket? _socket;
  html.MediaStream? _localStream;
  html.MediaStream? _remoteStream;
  late final html.VideoElement _localVideo;
  late final html.VideoElement _remoteVideo;
  late final String _localVideoViewType;
  late final String _remoteVideoViewType;
  final List<Map<String, dynamic>> _pendingCandidates = [];
  final List<String> _pendingMessages = [];
  final List<Map<String, dynamic>> _pendingEncryptedPayloads = [];
  final Map<String, IncomingAttachmentPayload> _incomingAttachments = {};
  JSAny? _privateKey;
  JSAny? _aesKey;
  String? _e2eePublicKey;
  Map<String, dynamic>? _pendingEncryptionKey;
  bool _encryptionHandshakeStarted = false;
  String? _roomKeyStorageKey;
  bool _remoteDescriptionSet = false;
  bool _offerStarted = false;
  bool _closed = false;
  Future<void> _peerConnectionReady = Future<void>.value();
  Future<void> _signalTail = Future<void>.value();
  int _peerConnectionResetGeneration = 0;
  int _socketGeneration = 0;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  bool _screenShareEnabled = false;
  bool _screenSharePaused = false;
  int _screenCaptureGeneration = 0;
  CallState _callState = CallState.idle;
  static int _nextViewId = 0;
  static int _nextAttachmentId = 0;
  // Keep encrypted JSON envelopes below mobile WebRTC/SCTP message limits.
  static const int _attachmentChunkSize = attachmentChunkChars;

  bool get canSend => _dataChannel?.readyState == 'open';
  bool get canStoreOffline =>
      _socket?.readyState == html.WebSocket.OPEN && encryptionReady;
  bool get canMessage => canSend || canStoreOffline;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
  bool get screenShareEnabled => _screenShareEnabled;
  bool get screenSharePaused => _screenShareEnabled && _screenSharePaused;
  bool get encryptionReady => _aesKey != null;
  CallState get callState => _callState;
  bool get callActive => _callState != CallState.idle;
  String get localVideoViewType => _localVideoViewType;
  String? get remoteVideoViewType =>
      _hasLiveVideo(_remoteStream) ? _remoteVideoViewType : null;

  void _registerVideoViews() {
    final id = _nextViewId++;
    _localVideoViewType = 'peep-local-video-$id';
    _remoteVideoViewType = 'peep-remote-video-$id';
    _localVideo = _createVideoElement(muted: true);
    _remoteVideo = _createVideoElement(muted: false);

    ui_web.platformViewRegistry.registerViewFactory(
      _localVideoViewType,
      (int viewId) => _localVideo,
    );
    ui_web.platformViewRegistry.registerViewFactory(
      _remoteVideoViewType,
      (int viewId) => _remoteVideo,
    );
  }

  html.VideoElement _createVideoElement({required bool muted}) {
    final video = html.VideoElement()
      ..autoplay = true
      ..muted = muted
      ..controls = false
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.pointerEvents = 'none'
      ..style.backgroundColor = '#111827';
    video.onCanPlay.listen((_) => _resumeVideo(video));
    return video;
  }

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
    String? authToken,
    String? accountUsername,
    String? contactUsername,
  }) async {
    final effectiveRoom = accountUsername != null && contactUsername != null
        ? directConversationId(accountUsername, contactUsername)
        : room.trim();
    final pendingMessages =
        _roomKeyStorageKey == 'peep:e2ee-room:$effectiveRoom'
        ? List<String>.of(_pendingMessages)
        : const <String>[];
    await disconnect();
    _closed = false;
    final peerConnectionGeneration = ++_peerConnectionResetGeneration;
    _socketGeneration++;
    _remoteDescriptionSet = false;
    _offerStarted = false;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    _callState = CallState.idle;
    _pendingCandidates.clear();
    _pendingMessages
      ..clear()
      ..addAll(pendingMessages);
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _privateKey = null;
    _aesKey = null;
    _pendingEncryptionKey = null;
    _encryptionHandshakeStarted = false;
    _e2eePublicKey = null;
    _roomKeyStorageKey = 'peep:e2ee-room:$effectiveRoom';
    await _loadPersistedRoomKey();

    onStatus(PeerStatus.signaling);
    _peerConnectionReady = _createPeerConnection(peerConnectionGeneration);
    await _peerConnectionReady;

    final queryParameters = <String, String>{
      ...signalingUri.queryParameters,
      if (authToken != null && contactUsername != null) ...{
        'token': authToken,
        'contact': contactUsername,
      } else ...{
        'room': room,
        'peer': peerId,
      },
    };
    final url = signalingUri.replace(queryParameters: queryParameters);

    await _connectSocket(url);
    onStatus(PeerStatus.waitingForPeer);
  }

  void send(String text) {
    if (!canMessage) {
      _pendingMessages.add(text);
      onLog('Queued message until an encrypted channel is ready.');
      return;
    }

    _sendDataChannelMessage(text);
  }

  Future<void> pickAndSendAttachment() async {
    if (!canMessage) {
      onLog('Connect encrypted chat before sending an attachment.');
      return;
    }

    final file = await _pickWebAttachmentFile();
    if (file == null) return;
    validateAttachmentSize(file.size);
    final bytes = await _readWebAttachmentBytes(file);
    final mimeType = resolveAttachmentMimeType(
      name: file.name,
      bytes: bytes,
      fallback: file.type,
    );
    validateAttachmentMetadata(
      name: file.name,
      mimeType: mimeType,
      size: bytes.length,
    );
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final attachment = _createAttachmentData(
      name: file.name,
      mimeType: mimeType,
      size: bytes.length,
      dataUrl: dataUrl,
    );

    onMessage(
      ChatMessage(
        text: file.name,
        isLocal: true,
        sentAt: DateTime.now(),
        attachment: attachment,
      ),
    );

    await _sendAttachment(attachment: attachment);
  }

  void startCall() {
    if (!canSend) {
      onLog('Wait for the chat connection before starting a call.');
      return;
    }
    if (_callState != CallState.idle) {
      return;
    }

    _callState = CallState.outgoing;
    _sendControl({'kind': 'call-request'});
    onLog('Call request sent.');
    onMediaChanged();
  }

  Future<void> acceptCall() async {
    if (_callState != CallState.incoming) {
      return;
    }

    try {
      _callState = CallState.active;
      // Send acceptance before media renegotiation so the caller can start
      // the offer/answer exchange from the established data channel.
      await _sendControl({'kind': 'call-accept'});
      onLog('Call accepted. Waiting for caller media offer.');
      onMediaChanged();
    } catch (error) {
      _callState = CallState.idle;
      _sendControl({'kind': 'call-decline'});
      onLog('Could not start microphone: $error');
      onMediaChanged();
    }
  }

  void declineCall() {
    if (_callState != CallState.incoming) {
      return;
    }

    _callState = CallState.idle;
    _sendControl({'kind': 'call-decline'});
    onLog('Call declined.');
    onMediaChanged();
  }

  Future<void> endCall() async {
    if (_callState == CallState.idle) {
      return;
    }

    _sendControl({'kind': 'call-end'});
    await _stopCallMedia();
    onLog('Call ended.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    _screenCaptureGeneration++;
    if (_callState != CallState.active) {
      onLog('Start a call before turning on video.');
      return;
    }

    if (enabled &&
        (_screenShareEnabled ||
            _localStream?.getVideoTracks().isEmpty != false)) {
      try {
        if (_screenShareEnabled) {
          await _stopLocalVideoTracks();
        }
        _screenShareEnabled = false;
        final needsAudio = _localStream?.getAudioTracks().isEmpty != false;
        await _startLocalMedia(audio: needsAudio, video: true);
        await _createAndSendOffer();
      } catch (error) {
        _cameraEnabled = false;
        onLog('Could not start camera: $error');
        onMediaChanged();
      }
      return;
    }

    if (!enabled) {
      final stopped = await _stopLocalVideoTracks();
      _cameraEnabled = false;
      _screenShareEnabled = false;
      if (stopped) {
        await _createAndSendOffer();
      }
      onLog('Camera turned off.');
      onMediaChanged();
      return;
    }

    _cameraEnabled = enabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <html.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Camera enabled.' : 'Camera disabled.');
    onMediaChanged();
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a call before changing microphone state.');
      return;
    }

    if (enabled && _localStream?.getAudioTracks().isEmpty != false) {
      try {
        final needsVideo =
            _cameraEnabled && _localStream?.getVideoTracks().isEmpty != false;
        await _startLocalMedia(audio: true, video: needsVideo);
        await _createAndSendOffer();
      } catch (error) {
        _microphoneEnabled = false;
        onLog('Could not start microphone: $error');
        onMediaChanged();
      }
      return;
    }

    _microphoneEnabled = enabled;
    for (final track
        in _localStream?.getAudioTracks() ?? <html.MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Microphone enabled.' : 'Microphone muted.');
    onMediaChanged();
  }

  Future<void> setScreenSharePaused(bool paused) async {
    if (!_screenShareEnabled || _callState != CallState.active) return;
    final connection = _peerConnection;
    if (connection == null) return;
    try {
      await applyWebSenderLimits(
        connection,
        _mediaSettings,
        screenSharing: true,
        screenPaused: paused,
      );
      _screenSharePaused = paused;
      for (final track
          in _localStream?.getVideoTracks() ?? <html.MediaStreamTrack>[]) {
        track.enabled = !paused;
      }
      onLog(paused ? 'Screen sharing paused.' : 'Screen sharing resumed.');
      onMediaChanged();
    } catch (error) {
      onLog('Could not update screen sharing: $error');
    }
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a call before sharing your screen.');
      return;
    }
    final generation = ++_screenCaptureGeneration;
    if (!enabled) {
      final stopped = await _stopLocalVideoTracks();
      _screenShareEnabled = false;
      _cameraEnabled = false;
      if (stopped) {
        await _createAndSendOffer();
      }
      onLog('Screen sharing stopped.');
      onMediaChanged();
      return;
    }
    try {
      final screen = await _getDisplayMedia(_mediaSettings);
      final tracks = _videoTracksFromJsStream(screen);
      if (generation != _screenCaptureGeneration ||
          _closed ||
          _callState != CallState.active) {
        for (final track in tracks) {
          track.callMethod<JSAny?>('stop'.toJS);
        }
        return;
      }
      if (tracks.isEmpty) {
        throw StateError('No screen video track was selected.');
      }
      final paused = screenSharePaused;
      await _stopLocalVideoTracks();
      _localStream ??= html.MediaStream();
      for (final track in tracks) {
        _addJsTrackToMediaStream(_localStream!, track);
        await attachWebMediaTrack(_peerConnection!, _localStream!, track);
        track['enabled'] = (!paused).toJS;
        _onJsTrackEnded(track, () {
          if (_screenShareEnabled &&
              _localStream?.getVideoTracks().any(
                    (current) =>
                        identical(JSObject.fromInteropObject(current), track),
                  ) ==
                  true) {
            unawaited(setScreenShareEnabled(false));
          }
        });
      }
      _setVideoStream(_localVideo, _localStream);
      _screenShareEnabled = true;
      _screenSharePaused = paused;
      _cameraEnabled = false;
      await _createAndSendOffer();
      onLog('Screen sharing started.');
      onMediaChanged();
    } catch (error) {
      if (generation != _screenCaptureGeneration) return;
      onLog('Could not share screen: $error');
      onMediaChanged();
    }
  }

  Future<void> disconnect() async {
    _closed = true;
    _peerConnectionResetGeneration++;
    _socketGeneration++;
    final pendingPeerConnection = _peerConnectionReady;
    try {
      await pendingPeerConnection;
    } catch (_) {
      // Continue releasing the socket and media when peer setup failed.
    }
    final dataChannel = _dataChannel;
    final peerConnection = _peerConnection;
    _dataChannel = null;
    _peerConnection = null;
    dataChannel?.close();
    peerConnection?.close();
    _socket?.close();
    _localStream?.getTracks().forEach((track) => track.stop());
    _remoteStream?.getTracks().forEach((track) => track.stop());
    _dataChannel = null;
    _peerConnection = null;
    _socket = null;
    _localStream = null;
    _remoteStream = null;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    _callState = CallState.idle;
    _setVideoStream(_localVideo, null);
    _setVideoStream(_remoteVideo, null);
    _pendingMessages.clear();
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _privateKey = null;
    _aesKey = null;
    _pendingEncryptionKey = null;
    _encryptionHandshakeStarted = false;
    _e2eePublicKey = null;
    _roomKeyStorageKey = null;
    _peerConnectionReady = Future<void>.value();
    onStatus(PeerStatus.disconnected);
    onMediaChanged();
  }

  Future<void> _createPeerConnection(int generation) async {
    if (_closed || generation != _peerConnectionResetGeneration) return;
    final peerConnection = html.RtcPeerConnection({'iceServers': []});
    _peerConnection = peerConnection;
    _wirePeerConnection(peerConnection);
    peerConnection.onDataChannel.listen((event) {
      final channel = event.channel;
      if (channel != null && identical(_peerConnection, peerConnection)) {
        _attachDataChannel(channel);
      }
    });
  }

  void _wirePeerConnection(html.RtcPeerConnection peerConnection) {
    peerConnection.onIceCandidate.listen((event) {
      if (!identical(_peerConnection, peerConnection)) return;
      final candidate = event.candidate;
      if (candidate == null) {
        return;
      }

      _sendSignal({
        'type': 'candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    });

    peerConnection.onConnectionStateChange.listen((_) {
      if (!identical(_peerConnection, peerConnection)) return;
      switch (peerConnection.connectionState) {
        case 'connected':
          if (canSend) onStatus(PeerStatus.connected);
          break;
        case 'connecting':
          onStatus(PeerStatus.connecting);
          break;
        case 'failed':
          onStatus(PeerStatus.failed);
          break;
        case 'closed':
          if (!_closed) {
            onStatus(PeerStatus.disconnected);
          }
          break;
      }
    });

    peerConnection.onIceConnectionStateChange.listen((_) {
      if (!identical(_peerConnection, peerConnection)) return;
      onLog('ICE state: ${peerConnection.iceConnectionState ?? 'unknown'}');
    });

    peerConnection.onTrack.listen((event) {
      if (!identical(_peerConnection, peerConnection)) return;
      final stream = event.streams?.isNotEmpty == true
          ? event.streams!.first
          : _remoteStream ?? html.MediaStream();
      final track = event.track;
      if (track?.kind == 'video') {
        void refresh(_) {
          if (identical(_peerConnection, peerConnection)) onMediaChanged();
        }

        track!.onMute.listen(refresh);
        track.onUnmute.listen(refresh);
        track.onEnded.listen(refresh);
      }
      if (event.streams?.isNotEmpty != true && track != null) {
        stream.addTrack(track);
      }

      _remoteStream = stream;
      _setVideoStream(_remoteVideo, stream);
      onLog('Remote ${track?.kind ?? 'media'} track received.');
      onMediaChanged();
    });
  }

  Future<void> _startLocalMedia({
    required bool audio,
    required bool video,
  }) async {
    if (!audio && !video) {
      return;
    }

    onLog(
      'Requesting ${video ? 'camera' : ''}${video && audio ? ' and ' : ''}${audio ? 'microphone' : ''}.',
    );
    final stream = await html.window.navigator.mediaDevices!.getUserMedia({
      'audio': audio ? _mediaSettings.audioConstraints : false,
      'video': video ? _mediaSettings.videoConstraints : false,
    });

    _localStream ??= html.MediaStream();
    for (final track in stream.getTracks()) {
      _localStream!.addTrack(track);
      await attachWebMediaTrack(
        _peerConnection!,
        _localStream!,
        JSObject.fromInteropObject(track),
      );
    }
    _setVideoStream(_localVideo, _localStream);
    _cameraEnabled = _localStream!.getVideoTracks().any(
      (track) => track.enabled == true,
    );
    _microphoneEnabled = _localStream!.getAudioTracks().any(
      (track) => track.enabled == true,
    );

    onLog(
      '${video ? 'Camera' : ''}${video && audio ? ' and ' : ''}${audio ? 'microphone' : ''} ready.',
    );
    onMediaChanged();
  }

  Future<bool> _stopLocalVideoTracks() async {
    final connection = _peerConnection;
    if (connection != null) await detachWebVideoSenders(connection);
    _screenSharePaused = false;
    final stream = _localStream;
    if (stream == null) {
      _setVideoStream(_localVideo, null);
      return false;
    }

    final videoTracks = List<html.MediaStreamTrack>.from(
      stream.getVideoTracks(),
    );
    if (videoTracks.isEmpty) {
      return false;
    }

    for (final track in videoTracks) {
      track.stop();
      stream.removeTrack(track);
    }
    _setVideoStream(_localVideo, stream.getTracks().isEmpty ? null : stream);
    return true;
  }

  void _attachDataChannel(html.RtcDataChannel channel) {
    _dataChannel = channel;

    channel.onOpen.listen((_) {
      if (identical(_dataChannel, channel)) {
        unawaited(_handleDataChannelOpen(channel));
      }
    });

    channel.onClose.listen((_) {
      if (!_closed && identical(_dataChannel, channel)) {
        _dataChannel = null;
        onStatus(PeerStatus.waitingForPeer);
        onMediaChanged();
      }
      onLog('Data channel closed.');
    });

    channel.onMessage.listen((event) {
      if (identical(_dataChannel, channel)) {
        final data = event.data;
        if (data is String) {
          _handleDataChannelMessage(data);
        }
      }
    });
  }

  Future<void> _handleDataChannelOpen(html.RtcDataChannel channel) async {
    if (_closed || !identical(_dataChannel, channel)) return;
    onStatus(PeerStatus.connected);
    onLog('Data channel opened.');
    try {
      await _startEncryptionHandshake();
      _flushPendingMessages();
    } catch (error) {
      onStatus(PeerStatus.failed);
      onLog('E2EE setup failed: $error');
    }
  }

  void _handleDataChannelMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        if (decoded['kind'] == 'e2ee-key') {
          unawaited(_handleEncryptionKey(decoded));
          return;
        }
        if (decoded['kind'] == 'e2ee') {
          unawaited(_handleEncryptedPayload(decoded));
          return;
        }
        onLog('Ignored unencrypted data-channel payload.');
      }
    } catch (_) {
      onLog('Ignored unreadable data-channel payload.');
    }
  }

  void _handleAppPayload(Map<String, dynamic> decoded) {
    switch (decoded['kind']) {
      case 'chat':
        final text = decoded['text'];
        if (text is String) {
          onMessage(
            ChatMessage(text: text, isLocal: false, sentAt: DateTime.now()),
          );
        }
        return;
      case 'attachment-start':
        _handleAttachmentStart(decoded);
        return;
      case 'attachment-chunk':
        _handleAttachmentChunk(decoded);
        return;
      case 'attachment-end':
        _handleAttachmentEnd(decoded);
        return;
      case 'call-request':
        if (_callState == CallState.idle) {
          _callState = CallState.incoming;
          onLog('Incoming call request.');
          onMediaChanged();
        } else {
          unawaited(_sendControl({'kind': 'call-decline'}));
        }
        return;
      case 'call-accept':
        unawaited(_handleCallAccepted());
        return;
      case 'call-decline':
        if (_callState == CallState.outgoing) {
          _callState = CallState.idle;
          onLog('Call declined.');
          onMediaChanged();
        }
        return;
      case 'call-end':
        unawaited(_stopCallMedia());
        onLog('Peer ended the call.');
        return;
    }
  }

  Future<void> _handleCallAccepted() async {
    if (_callState != CallState.outgoing) {
      return;
    }

    try {
      await _startLocalMedia(audio: true, video: false);
      _callState = CallState.active;
      onLog('Call accepted. Starting audio.');
      onMediaChanged();
      await _createAndSendOffer();
    } catch (error) {
      _callState = CallState.idle;
      _sendControl({'kind': 'call-end'});
      onLog('Could not start microphone: $error');
      onMediaChanged();
    }
  }

  Future<void> _stopCallMedia() async {
    _screenCaptureGeneration++;
    _screenSharePaused = false;
    _localStream?.getTracks().forEach((track) => track.stop());
    _remoteStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;
    _remoteStream = null;
    _setVideoStream(_localVideo, null);
    _setVideoStream(_remoteVideo, null);
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    _callState = CallState.idle;
    onMediaChanged();
  }

  void _flushPendingMessages() {
    if (!canSend || _pendingMessages.isEmpty) {
      return;
    }

    final messages = List<String>.from(_pendingMessages);
    _pendingMessages.clear();

    for (final message in messages) {
      _sendDataChannelMessage(message);
    }
  }

  void _sendDataChannelMessage(String text) {
    unawaited(_sendControl({'kind': 'chat', 'text': text}));
    onMessage(ChatMessage(text: text, isLocal: true, sentAt: DateTime.now()));
  }

  Future<void> _sendAttachment({required AttachmentData attachment}) async {
    validateAttachmentMetadata(
      name: attachment.name,
      mimeType: attachment.mimeType,
      size: attachment.size,
    );
    if (!isValidAttachmentDataUrl(
      dataUrl: attachment.dataUrl,
      mimeType: attachment.mimeType,
      size: attachment.size,
    )) {
      throw StateError('Could not prepare the selected attachment.');
    }
    final id =
        'attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}';
    await _sendControl({
      'kind': 'attachment-start',
      'id': id,
      'name': attachment.name,
      'mimeType': attachment.mimeType,
      'size': attachment.size,
    });

    for (
      var offset = 0;
      offset < attachment.dataUrl.length;
      offset += _attachmentChunkSize
    ) {
      final chunkEnd = offset + _attachmentChunkSize;
      final end = chunkEnd > attachment.dataUrl.length
          ? attachment.dataUrl.length
          : chunkEnd;
      await _sendControl({
        'kind': 'attachment-chunk',
        'id': id,
        'data': attachment.dataUrl.substring(offset, end),
      });
      await _waitForBufferedAmount();
    }

    await _sendControl({'kind': 'attachment-end', 'id': id});
    onLog('Attachment sent: ${attachment.name}.');
  }

  Future<void> _waitForBufferedAmount() async {
    while ((_dataChannel?.bufferedAmount ?? 0) > 512 * 1024) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void _handleAttachmentStart(Map<String, dynamic> message) {
    final id = message['id'];
    final name = message['name'];
    final mimeType = message['mimeType'];
    final size = message['size'];
    if (id is! String ||
        name is! String ||
        mimeType is! String ||
        size is! int) {
      return;
    }

    final normalizedMimeType = normalizeAttachmentMimeType(mimeType);
    if (id.isEmpty || id.length > 128) return;
    try {
      validateAttachmentMetadata(
        name: name,
        mimeType: normalizedMimeType,
        size: size,
      );
    } on StateError {
      onLog('Discarded an invalid or oversized attachment.');
      return;
    }
    _incomingAttachments[id] = IncomingAttachmentPayload(
      name: name,
      mimeType: normalizedMimeType,
      size: size,
    );
    onLog('Receiving attachment: $name.');
  }

  void _handleAttachmentChunk(Map<String, dynamic> message) {
    final id = message['id'];
    final data = message['data'];
    if (id is! String || data is! String) {
      return;
    }

    final incoming = _incomingAttachments[id];
    if (incoming != null && !incoming.appendChunk(data)) {
      _incomingAttachments.remove(id);
      onLog('Discarded an invalid attachment chunk.');
    }
  }

  void _handleAttachmentEnd(Map<String, dynamic> message) {
    final id = message['id'];
    if (id is! String) {
      return;
    }

    final incoming = _incomingAttachments.remove(id);
    if (incoming == null) {
      return;
    }

    final dataUrl = incoming.takeValidatedDataUrl();
    if (dataUrl == null) {
      onLog('Discarded an incomplete or invalid attachment.');
      return;
    }
    final attachment = _createAttachmentData(
      name: incoming.name,
      mimeType: incoming.mimeType,
      size: incoming.size,
      dataUrl: dataUrl,
    );
    onMessage(
      ChatMessage(
        text: incoming.name,
        isLocal: false,
        sentAt: DateTime.now(),
        attachment: attachment,
      ),
    );
    onLog('Attachment received: ${incoming.name}.');
  }

  AttachmentData _createAttachmentData({
    required String name,
    required String mimeType,
    required int size,
    required String dataUrl,
  }) {
    final isAudio = mimeType.startsWith('audio/');
    final isVideo = mimeType.startsWith('video/');
    String? viewType;

    if (isAudio || isVideo) {
      viewType =
          'peep-attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}';
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
        if (isVideo) {
          return html.VideoElement()
            ..src = dataUrl
            ..controls = true
            ..preload = 'metadata'
            ..setAttribute('playsinline', 'true')
            ..style.width = '100%'
            ..style.height = '100%'
            ..style.objectFit = 'cover'
            ..style.backgroundColor = '#111827';
        }

        return html.AudioElement()
          ..src = dataUrl
          ..controls = true
          ..preload = 'metadata'
          ..style.width = '100%'
          ..style.height = '100%';
      });
    }

    return AttachmentData(
      name: name,
      mimeType: mimeType,
      size: size,
      dataUrl: dataUrl,
      viewType: viewType,
    );
  }

  Future<void> _sendControl(Map<String, dynamic> message) async {
    if (!encryptionReady) {
      _pendingEncryptedPayloads.add(message);
      onLog('Queued encrypted payload until E2EE is ready.');
      return;
    }

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    final iv = Uint8List(12);
    html.window.crypto!.getRandomValues(iv);
    final ciphertext = await _encryptBytes(plaintext: plaintext, iv: iv);
    final envelope = {
      'kind': 'e2ee',
      'iv': base64Encode(iv),
      'ciphertext': base64Encode(ciphertext),
    };

    if (canSend) {
      _sendPlainDataChannel(envelope);
      return;
    }
    if (canStoreOffline) {
      _storeEncryptedPayload(envelope);
      return;
    }

    onLog('No encrypted transport or offline mailbox is available.');
  }

  void _sendPlainDataChannel(Map<String, dynamic> message) {
    if (!canSend) {
      onLog('Data channel is not open.');
      return;
    }

    _dataChannel!.sendString(jsonEncode(message));
  }

  void _storeEncryptedPayload(Map<String, dynamic> envelope) {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      onLog('Signaling socket is not open.');
      return;
    }

    socket.sendString(jsonEncode({'type': 'store', 'payload': envelope}));
    onLog('Stored encrypted payload for offline delivery.');
  }

  Future<void> _startEncryptionHandshake() async {
    if (_encryptionHandshakeStarted) {
      return;
    }
    _encryptionHandshakeStarted = true;
    final subtle = _subtleCrypto;
    final keyPair = await subtle
        .callMethod<JSPromise<JSObject>>(
          'generateKey'.toJS,
          {'name': 'ECDH', 'namedCurve': 'P-256'}.jsify(),
          true.toJS,
          ['deriveKey'].jsify(),
        )
        .toDart;
    _privateKey = keyPair['privateKey'];
    final publicKey = keyPair['publicKey'];
    if (_privateKey == null || publicKey == null) {
      throw StateError('Could not generate E2EE key pair.');
    }

    final publicBytes = await subtle
        .callMethod<JSPromise<JSArrayBuffer>>(
          'exportKey'.toJS,
          'raw'.toJS,
          publicKey,
        )
        .toDart;
    _e2eePublicKey = base64Encode(publicBytes.toDart.asUint8List());
    _sendE2eePublicKey();
    onLog('E2EE key sent.');
    _retryE2eePublicKey(_e2eePublicKey!);

    final pendingKey = _pendingEncryptionKey;
    _pendingEncryptionKey = null;
    if (pendingKey != null) {
      await _handleEncryptionKey(pendingKey);
    }
  }

  void _sendE2eePublicKey() {
    final publicKey = _e2eePublicKey;
    if (publicKey == null) return;
    _sendPlainDataChannel({'kind': 'e2ee-key', 'publicKey': publicKey});
  }

  void _retryE2eePublicKey(String publicKey) {
    for (final delay in const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 750),
      Duration(milliseconds: 1500),
    ]) {
      unawaited(
        Future<void>.delayed(delay, () {
          if (!_closed && _e2eePublicKey == publicKey) {
            _sendE2eePublicKey();
          }
        }),
      );
    }
  }

  Future<void> _handleEncryptionKey(Map<String, dynamic> message) async {
    final publicKey = message['publicKey'];
    if (publicKey is! String || _aesKey != null) {
      return;
    }
    if (_privateKey == null) {
      _pendingEncryptionKey = Map<String, dynamic>.from(message);
      onLog('Received E2EE key before local key generation completed.');
      return;
    }

    final subtle = _subtleCrypto;
    final peerPublicKey = await subtle.callMethodVarArgs<JSPromise<JSAny>>(
      'importKey'.toJS,
      [
        'raw'.toJS,
        Uint8List.fromList(base64Decode(publicKey)).toJS,
        {'name': 'ECDH', 'namedCurve': 'P-256'}.jsify(),
        true.toJS,
        <String>[].jsify(),
      ],
    ).toDart;

    final deriveParams = {'name': 'ECDH'}.jsify() as JSObject;
    deriveParams['public'] = peerPublicKey;
    _aesKey = await subtle.callMethodVarArgs<JSPromise<JSAny>>(
      'deriveKey'.toJS,
      [
        deriveParams,
        _privateKey,
        {'name': 'AES-GCM', 'length': 256}.jsify(),
        true.toJS,
        ['encrypt', 'decrypt'].jsify(),
      ],
    ).toDart;
    await _persistRoomKey();
    _sendE2eePublicKey();
    onLog('E2EE ready.');
    onMediaChanged();
    unawaited(_flushPendingEncryptedPayloads());
  }

  Future<void> _handleEncryptedPayload(Map<String, dynamic> message) async {
    if (!encryptionReady) {
      onLog('Encrypted payload arrived before E2EE was ready.');
      return;
    }

    final iv = message['iv'];
    final ciphertext = message['ciphertext'];
    if (iv is! String || ciphertext is! String) {
      return;
    }

    try {
      final plaintext = await _decryptBytes(
        ciphertext: Uint8List.fromList(base64Decode(ciphertext)),
        iv: Uint8List.fromList(base64Decode(iv)),
      );
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is Map<String, dynamic>) {
        _handleAppPayload(decoded);
      }
    } catch (error) {
      onLog('Could not decrypt payload: $error');
    }
  }

  Future<void> _flushPendingEncryptedPayloads() async {
    if (!encryptionReady || _pendingEncryptedPayloads.isEmpty) {
      return;
    }

    final payloads = List<Map<String, dynamic>>.from(_pendingEncryptedPayloads);
    _pendingEncryptedPayloads.clear();
    for (final payload in payloads) {
      await _sendControl(payload);
    }
  }

  Future<void> _loadPersistedRoomKey() async {
    final storageKey = _roomKeyStorageKey;
    if (storageKey == null) {
      return;
    }

    final encodedKey = html.window.localStorage[storageKey];
    if (encodedKey == null || encodedKey.isEmpty) {
      return;
    }

    try {
      _aesKey = await _subtleCrypto.callMethodVarArgs<JSPromise<JSAny>>(
        'importKey'.toJS,
        [
          'raw'.toJS,
          Uint8List.fromList(base64Decode(encodedKey)).toJS,
          {'name': 'AES-GCM'}.jsify(),
          true.toJS,
          ['encrypt', 'decrypt'].jsify(),
        ],
      ).toDart;
      onLog('Loaded saved E2EE room key.');
      onMediaChanged();
    } catch (error) {
      html.window.localStorage.remove(storageKey);
      onLog('Saved E2EE room key could not be loaded: $error');
    }
  }

  Future<void> _persistRoomKey() async {
    final storageKey = _roomKeyStorageKey;
    if (storageKey == null || _aesKey == null) {
      return;
    }

    try {
      final rawKey = await _subtleCrypto
          .callMethod<JSPromise<JSArrayBuffer>>(
            'exportKey'.toJS,
            'raw'.toJS,
            _aesKey,
          )
          .toDart;
      html.window.localStorage[storageKey] = base64Encode(
        rawKey.toDart.asUint8List(),
      );
    } catch (error) {
      onLog('Could not persist E2EE room key: $error');
    }
  }

  Future<Uint8List> _encryptBytes({
    required Uint8List plaintext,
    required Uint8List iv,
  }) async {
    final params = {'name': 'AES-GCM'}.jsify() as JSObject;
    params['iv'] = iv.toJS;
    final ciphertext = await _subtleCrypto
        .callMethod<JSPromise<JSArrayBuffer>>(
          'encrypt'.toJS,
          params,
          _aesKey,
          plaintext.toJS,
        )
        .toDart;
    return ciphertext.toDart.asUint8List();
  }

  Future<Uint8List> _decryptBytes({
    required Uint8List ciphertext,
    required Uint8List iv,
  }) async {
    final params = {'name': 'AES-GCM'}.jsify() as JSObject;
    params['iv'] = iv.toJS;
    final plaintext = await _subtleCrypto
        .callMethod<JSPromise<JSArrayBuffer>>(
          'decrypt'.toJS,
          params,
          _aesKey,
          ciphertext.toJS,
        )
        .toDart;
    return plaintext.toDart.asUint8List();
  }

  JSObject get _subtleCrypto {
    final crypto = JSObject.fromInteropObject(html.window.crypto!);
    final subtle = crypto['subtle'];
    if (subtle == null) {
      throw StateError('WebCrypto is unavailable.');
    }
    return subtle as JSObject;
  }

  Future<void> _connectSocket(Uri uri) {
    final generation = _socketGeneration;
    final completer = Completer<void>();
    final socket = html.WebSocket(uri.toString());
    _socket = socket;

    socket.onOpen.listen((_) {
      if (_closed ||
          generation != _socketGeneration ||
          !identical(_socket, socket)) {
        return;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
      onLog('Signaling connected.');
    });

    socket.onError.listen((_) {
      if (generation != _socketGeneration || !identical(_socket, socket)) {
        return;
      }
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Could not connect to signaling server.'),
        );
      }
      onStatus(PeerStatus.failed);
      onLog('Signaling socket error.');
    });

    socket.onClose.listen((_) {
      if (!_closed &&
          generation == _socketGeneration &&
          identical(_socket, socket)) {
        onStatus(PeerStatus.disconnected);
      }
      if (generation == _socketGeneration && identical(_socket, socket)) {
        onLog('Signaling disconnected.');
      }
    });

    socket.onMessage.listen((event) {
      if (generation != _socketGeneration || !identical(_socket, socket)) {
        return;
      }
      final data = event.data;
      if (data is String) {
        _queueSignal(data, generation);
      }
    });

    return completer.future.timeout(const Duration(seconds: 8));
  }

  void _queueSignal(String raw, int generation) {
    _signalTail = _signalTail.then((_) async {
      if (_closed || generation != _socketGeneration) return;
      await _handleSignal(raw, generation);
    });
  }

  Future<void> _resetPeerConnectionAfterPeerLeft() async {
    final generation = ++_peerConnectionResetGeneration;
    final dataChannel = _dataChannel;
    final peerConnection = _peerConnection;
    _dataChannel = null;
    _peerConnection = null;
    _remoteDescriptionSet = false;
    _offerStarted = false;
    _pendingCandidates.clear();

    final reset = _finishPeerConnectionReset(
      generation,
      dataChannel,
      peerConnection,
    );
    _peerConnectionReady = reset;
    await reset;
  }

  Future<void> _finishPeerConnectionReset(
    int generation,
    html.RtcDataChannel? dataChannel,
    html.RtcPeerConnection? peerConnection,
  ) async {
    dataChannel?.close();
    peerConnection?.close();
    await _stopCallMedia();
    if (_closed ||
        generation != _peerConnectionResetGeneration ||
        _socket?.readyState != html.WebSocket.OPEN) {
      return;
    }
    await _createPeerConnection(generation);
    if (!_closed && generation == _peerConnectionResetGeneration) {
      onStatus(PeerStatus.waitingForPeer);
      onMediaChanged();
    }
  }

  Future<void> _createAndSendOffer({bool ensureDataChannel = false}) async {
    await _peerConnectionReady;
    if (ensureDataChannel && _offerStarted) {
      return;
    }

    if (ensureDataChannel) {
      _offerStarted = true;
    }
    final peerConnection = _peerConnection;
    if (peerConnection == null || _closed) return;
    onStatus(PeerStatus.connecting);
    if (ensureDataChannel && _dataChannel == null) {
      _attachDataChannel(peerConnection.createDataChannel('chat'));
    }
    final offer = await _createDescription('createOffer', peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    await _setLocalDescription(offer, peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    await _applySenderLimits(peerConnection);
    _sendSignal({'type': 'offer', 'description': offer});
  }

  Future<void> _handleSignal(String raw, int generation) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      switch (decoded['type']) {
        case 'welcome':
          await _handleWelcome(decoded);
          break;
        case 'presence':
          if (decoded['event'] == 'left') {
            await _resetPeerConnectionAfterPeerLeft();
          }
          onLog('Peer ${decoded['peer']} ${decoded['event']}.');
          break;
        case 'stored':
          final payload = decoded['payload'];
          if (payload is Map<String, dynamic>) {
            unawaited(_handleEncryptedPayload(payload));
          }
          break;
        case 'error':
          onStatus(PeerStatus.failed);
          onLog('${decoded['message'] ?? 'Signaling error.'}');
          break;
        case 'offer':
          await _handleOffer(decoded);
          break;
        case 'answer':
          await _handleAnswer(decoded);
          break;
        case 'candidate':
          await _handleCandidate(decoded);
          break;
      }
    } catch (error) {
      if (_closed || generation != _socketGeneration) return;
      onStatus(PeerStatus.failed);
      onLog('Signal handling failed: $error');
    }
  }

  Future<void> _handleWelcome(Map<String, dynamic> signal) async {
    await _peerConnectionReady;
    final existingPeers = signal['existingPeers'];
    if (existingPeers is int && existingPeers > 0) {
      onLog('Room already has a peer. Starting WebRTC offer.');
      await _createAndSendOffer(ensureDataChannel: true);
      return;
    }

    onStatus(PeerStatus.waitingForPeer);
    onLog('Waiting for another peer in this room.');
  }

  Future<void> _handleOffer(Map<String, dynamic> signal) async {
    await _peerConnectionReady;
    final peerConnection = _peerConnection;
    if (peerConnection == null || _closed) return;
    final description = signal['description'];
    if (description is! Map<String, dynamic>) {
      return;
    }

    onStatus(PeerStatus.connecting);
    await _setRemoteDescription({
      'type': description['type'],
      'sdp': description['sdp'],
    }, peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    if (_callState == CallState.active &&
        _localStream?.getAudioTracks().isEmpty != false) {
      try {
        await _startLocalMedia(audio: true, video: false);
      } catch (error) {
        _callState = CallState.idle;
        await _sendControl({'kind': 'call-end'});
        onLog('Could not start microphone: $error');
        onMediaChanged();
        return;
      }
    }

    final answer = await _createDescription('createAnswer', peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    await _setLocalDescription(answer, peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    await _applySenderLimits(peerConnection);
    _sendSignal({'type': 'answer', 'description': answer});
  }

  Future<void> _handleAnswer(Map<String, dynamic> signal) async {
    await _peerConnectionReady;
    final peerConnection = _peerConnection;
    if (peerConnection == null || _closed) return;
    final description = signal['description'];
    if (description is! Map<String, dynamic>) {
      return;
    }

    await _setRemoteDescription({
      'type': description['type'],
      'sdp': description['sdp'],
    }, peerConnection);
    if (!identical(_peerConnection, peerConnection)) return;
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    await _applySenderLimits(peerConnection);
  }

  Future<void> _handleCandidate(Map<String, dynamic> signal) async {
    await _peerConnectionReady;
    if (_peerConnection == null || _closed) return;
    final candidate = signal['candidate'];
    if (candidate is! Map<String, dynamic>) {
      return;
    }

    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }

    await _addCandidate(candidate);
  }

  Future<void> _flushPendingCandidates() async {
    final candidates = List<Map<String, dynamic>>.from(_pendingCandidates);
    _pendingCandidates.clear();

    for (final candidate in candidates) {
      await _addCandidate(candidate);
    }
  }

  Future<Map<String, dynamic>> _createDescription(
    String method, [
    html.RtcPeerConnection? connection,
  ]) async {
    final rtcPeerConnection = connection ?? _peerConnection!;
    await applyWebCodecPreferences(rtcPeerConnection, _mediaSettings, onLog);
    final peerConnection = JSObject.fromInteropObject(rtcPeerConnection);
    final description = await peerConnection
        .callMethod<JSPromise<JSObject>>(method.toJS)
        .toDart;

    return {
      'type': (description['type'] as JSString?)?.toDart,
      'sdp': (description['sdp'] as JSString?)?.toDart,
    };
  }

  Future<void> _setLocalDescription(
    Map<String, dynamic> description, [
    html.RtcPeerConnection? connection,
  ]) {
    final peerConnection = JSObject.fromInteropObject(
      connection ?? _peerConnection!,
    );
    return peerConnection
        .callMethod<JSPromise<JSAny?>>(
          'setLocalDescription'.toJS,
          description.jsify(),
        )
        .toDart;
  }

  Future<void> _setRemoteDescription(
    Map<String, dynamic> description, [
    html.RtcPeerConnection? connection,
  ]) {
    final peerConnection = JSObject.fromInteropObject(
      connection ?? _peerConnection!,
    );
    return peerConnection
        .callMethod<JSPromise<JSAny?>>(
          'setRemoteDescription'.toJS,
          description.jsify(),
        )
        .toDart;
  }

  Future<void> _addCandidate(Map<String, dynamic> candidate) {
    final peerConnection = JSObject.fromInteropObject(_peerConnection!);
    return peerConnection
        .callMethod<JSPromise<JSAny?>>(
          'addIceCandidate'.toJS,
          {
            'candidate': candidate['candidate'],
            'sdpMid': candidate['sdpMid'],
            'sdpMLineIndex': candidate['sdpMLineIndex'],
          }.jsify(),
        )
        .toDart;
  }

  void _sendSignal(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      onLog('Signaling socket is not open.');
      return;
    }

    socket.sendString(jsonEncode(message));
  }
}

const int _maxStoredMessages = 500;
const String _historyStoragePrefix = 'peep:history:';
int _nextHistoryAttachmentId = 0;

String _historyStorageKey(String conversationKey) {
  return '$_historyStoragePrefix${conversationKey.trim().toLowerCase()}';
}

String _groupKeyStorageKey(String groupId) {
  return 'peep:group-key:$groupId';
}

Future<JSAny> _importAesGcmKey(String rawKeyBase64) {
  return _browserSubtleCrypto.callMethodVarArgs<JSPromise<JSAny>>(
    'importKey'.toJS,
    [
      'raw'.toJS,
      Uint8List.fromList(base64Decode(rawKeyBase64)).toJS,
      {'name': 'AES-GCM'}.jsify(),
      true.toJS,
      ['encrypt', 'decrypt'].jsify(),
    ],
  ).toDart;
}

Future<Uint8List> _aesGcmEncrypt({
  required JSAny key,
  required Uint8List plaintext,
  required Uint8List iv,
}) async {
  final params = {'name': 'AES-GCM'}.jsify() as JSObject;
  params['iv'] = iv.toJS;
  final ciphertext = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'encrypt'.toJS,
        params,
        key,
        plaintext.toJS,
      )
      .toDart;
  return ciphertext.toDart.asUint8List();
}

Future<Uint8List> _aesGcmDecrypt({
  required JSAny key,
  required Uint8List ciphertext,
  required Uint8List iv,
}) async {
  final params = {'name': 'AES-GCM'}.jsify() as JSObject;
  params['iv'] = iv.toJS;
  final plaintext = await _browserSubtleCrypto
      .callMethod<JSPromise<JSArrayBuffer>>(
        'decrypt'.toJS,
        params,
        key,
        ciphertext.toJS,
      )
      .toDart;
  return plaintext.toDart.asUint8List();
}

JSObject get _browserSubtleCrypto {
  final crypto = JSObject.fromInteropObject(html.window.crypto!);
  final subtle = crypto['subtle'];
  if (subtle == null) {
    throw StateError('WebCrypto is unavailable.');
  }
  return subtle as JSObject;
}

Map<String, dynamic> _messageToJson(ChatMessage message) {
  return {
    'text': message.text,
    'isLocal': message.isLocal,
    'sentAt': message.sentAt.toIso8601String(),
    if (message.sender != null) 'sender': message.sender,
    if (message.attachment != null)
      'attachment': _attachmentToJson(message.attachment!),
  };
}

Map<String, dynamic> _attachmentToJson(AttachmentData attachment) {
  return {
    'name': attachment.name,
    'mimeType': attachment.mimeType,
    'size': attachment.size,
    'dataUrl': attachment.dataUrl,
  };
}

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final attachment = json['attachment'];
  return ChatMessage(
    text: json['text'] is String ? json['text'] as String : '',
    isLocal: json['isLocal'] == true,
    sentAt:
        DateTime.tryParse(
          json['sentAt'] is String ? json['sentAt'] as String : '',
        ) ??
        DateTime.now(),
    sender: json['sender'] is String ? json['sender'] as String : null,
    attachment: attachment is Map<String, dynamic>
        ? _attachmentFromJson(attachment)
        : null,
  );
}

AttachmentData? _attachmentFromJson(Map<String, dynamic> json) {
  final name = json['name'];
  final mimeType = json['mimeType'];
  final size = json['size'];
  final dataUrl = json['dataUrl'];
  if (name is! String ||
      mimeType is! String ||
      size is! int ||
      dataUrl is! String) {
    return null;
  }

  final isAudio = mimeType.startsWith('audio/');
  final isVideo = mimeType.startsWith('video/');
  String? viewType;
  if (isAudio || isVideo) {
    viewType =
        'peep-history-attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextHistoryAttachmentId++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      if (isVideo) {
        return html.VideoElement()
          ..src = dataUrl
          ..controls = true
          ..preload = 'metadata'
          ..setAttribute('playsinline', 'true')
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'cover'
          ..style.backgroundColor = '#111827';
      }

      return html.AudioElement()
        ..src = dataUrl
        ..controls = true
        ..preload = 'metadata'
        ..style.width = '100%'
        ..style.height = '100%';
    });
  }

  return AttachmentData(
    name: name,
    mimeType: mimeType,
    size: size,
    dataUrl: dataUrl,
    viewType: viewType,
  );
}

Future<MediaCodecSupport> discoverMediaCodecs() => discoverWebMediaCodecs();
