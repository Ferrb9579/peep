import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

late SharedPreferencesWithCache _preferences;
final Map<String, RTCVideoRenderer> _videoRenderers = {};
final Map<String, AttachmentData> _attachmentViews = {};
int _nextNativeViewId = 0;

Future<void> initializePlatformServices() async {
  _preferences = await SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(),
  );
  _messageNotificationChannel.setMethodCallHandler((call) async {
    if (call.method == 'openChat') {
      final arguments = call.arguments;
      if (arguments is Map && arguments['contact'] is String) {
        _messageNotificationTapController.add(arguments['contact'] as String);
      }
    }
  });
}

const _messageNotificationChannel = MethodChannel('peep/message_notifications');
final _messageNotificationTapController = StreamController<String>.broadcast();

Stream<String> get messageNotificationTaps =>
    _messageNotificationTapController.stream;

Future<String?> takeInitialMessageNotificationContact() =>
    _messageNotificationChannel.invokeMethod<String>('takeInitialContact');

Future<void> startMessageNotifications({
  required Uri signalingUri,
  required AuthSession session,
}) async {
  final permission = await Permission.notification.request();
  if (!permission.isGranted) return;
  final watchUri = signalingUri.replace(
    queryParameters: {
      ...signalingUri.queryParameters,
      'token': session.token,
      'watch': '1',
    },
  );
  await _messageNotificationChannel.invokeMethod<void>('start', {
    'socketUrl': watchUri.toString(),
    'authToken': session.token,
    'username': session.username,
  });
}

Future<void> stopMessageNotifications() =>
    _messageNotificationChannel.invokeMethod<void>('stop');

Widget buildPlatformMediaView(String viewType) {
  final renderer = _videoRenderers[viewType];
  if (renderer != null) {
    return RTCVideoView(
      renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      mirror: viewType.contains('local'),
    );
  }
  final attachment = _attachmentViews[viewType];
  if (attachment != null) {
    return _NativeAttachmentPlayer(attachment: attachment);
  }
  return const Center(
    child: Text('Media unavailable', style: TextStyle(color: Colors.white70)),
  );
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

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    token: json['token'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
  );
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

  factory GroupSummary.fromJson(Map<String, dynamic> json) => GroupSummary(
    id: json['id'] as String,
    name: json['name'] as String,
    members: (json['members'] as List<dynamic>).whereType<String>().toList(
      growable: false,
    ),
  );
}

class AuthenticatedMemberKey {
  const AuthenticatedMemberKey({required this.username, this.publicKey});

  final String username;
  final String? publicKey;

  factory AuthenticatedMemberKey.fromJson(Map<String, dynamic> json) =>
      AuthenticatedMemberKey(
        username: json['username'] as String,
        publicKey: json['publicKey'] as String?,
      );
}

Future<AuthSession> createAccount({
  required Uri signalingUri,
  required String email,
  required String username,
  required String password,
}) => _postAuth(
  signalingUri: signalingUri,
  path: '/api/register',
  body: {'email': email, 'username': username, 'password': password},
);

Future<AuthSession> signInAccount({
  required Uri signalingUri,
  required String username,
  required String password,
}) => _postAuth(
  signalingUri: signalingUri,
  path: '/api/login',
  body: {'username': username, 'password': password},
);

Future<AuthSession> _postAuth({
  required Uri signalingUri,
  required String path,
  required Map<String, String> body,
}) async {
  final decoded = await _postJson(
    signalingUri: signalingUri,
    path: path,
    body: body,
  );
  return AuthSession.fromJson(decoded);
}

Future<GroupSummary> createGroup({
  required Uri signalingUri,
  required String token,
  required String name,
  required List<String> members,
}) async => GroupSummary.fromJson(
  await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/create',
    body: {'token': token, 'name': name, 'members': members},
  ),
);

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
  return groups is List
      ? groups
            .whereType<Map<String, dynamic>>()
            .map(GroupSummary.fromJson)
            .toList(growable: false)
      : const [];
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
  return chats is List
      ? chats
            .whereType<Map<String, dynamic>>()
            .map(MailboxSummary.fromJson)
            .toList(growable: false)
      : const [];
}

Future<Map<String, dynamic>> _postJson({
  required Uri signalingUri,
  required String path,
  required Map<String, dynamic> body,
}) async {
  final response = await http
      .post(
        _apiUri(signalingUri, path),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 15));
  Object? decoded;
  try {
    decoded = jsonDecode(response.body.isEmpty ? '{}' : response.body);
  } catch (_) {
    decoded = null;
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      throw StateError(decoded['error'] as String);
    }
    throw StateError('Request failed (${response.statusCode}).');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Response was invalid.');
  }
  return decoded;
}

Uri _apiUri(Uri signalingUri, String path) => signalingUri.replace(
  scheme: signalingUri.scheme == 'wss' ? 'https' : 'http',
  path: path,
  query: '',
);

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
  final publicStorageKey = 'peep:identity-public:$normalized';
  final privateStorageKey = 'peep:identity-private:$normalized';
  final storedPublic = _preferences.getString(publicStorageKey);
  final storedPrivate = _preferences.getString(privateStorageKey);
  if (storedPublic?.isNotEmpty == true && storedPrivate?.isNotEmpty == true) {
    return _IdentityKeyPair(
      publicKeyBase64: storedPublic!,
      privateKeyBase64: storedPrivate!,
    );
  }

  final pair = CryptoUtils.generateRSAKeyPair();
  final publicKey = pair.publicKey as RSAPublicKey;
  final privateKey = pair.privateKey as RSAPrivateKey;
  final generated = _IdentityKeyPair(
    publicKeyBase64: base64Encode(
      CryptoUtils.encodeRSAPublicKeyToDERBytes(publicKey),
    ),
    privateKeyBase64: base64Encode(
      CryptoUtils.encodeRSAPrivateKeyToDERBytes(privateKey),
    ),
  );
  await Future.wait([
    _preferences.setString(publicStorageKey, generated.publicKeyBase64),
    _preferences.setString(privateStorageKey, generated.privateKeyBase64),
  ]);
  return generated;
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
  final storageKey = _groupKeyStorageKey(group.id);
  if (_preferences.getString(storageKey)?.isNotEmpty == true) return;
  final rawKey = _secureRandomBytes(32);
  await _preferences.setString(storageKey, base64Encode(rawKey));
  await _publishGroupKeyEnvelopes(
    signalingUri: signalingUri,
    session: session,
    groupId: group.id,
    rawGroupKey: rawKey,
  );
}

Future<String> loadOrFetchGroupKey({
  required Uri signalingUri,
  required AuthSession session,
  required GroupSummary group,
}) async {
  final storageKey = _groupKeyStorageKey(group.id);
  final stored = _preferences.getString(storageKey);
  if (stored?.isNotEmpty == true) return stored!;

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
  final privateKey = CryptoUtils.rsaPrivateKeyFromDERBytes(
    Uint8List.fromList(base64Decode(identity.privateKeyBase64)),
  );
  final rawKey = _rsaOaepProcess(
    key: privateKey,
    input: Uint8List.fromList(base64Decode(encryptedKey)),
    encrypt: false,
  );
  final encoded = base64Encode(rawKey);
  await _preferences.setString(storageKey, encoded);
  return encoded;
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
  for (final json in members.whereType<Map<String, dynamic>>()) {
    final member = AuthenticatedMemberKey.fromJson(json);
    if (member.publicKey?.isNotEmpty != true) {
      throw StateError('Missing identity key for ${member.username}.');
    }
    final publicKey = CryptoUtils.rsaPublicKeyFromDERBytes(
      Uint8List.fromList(base64Decode(member.publicKey!)),
    );
    envelopes.add({
      'username': member.username,
      'encryptedKey': base64Encode(
        _rsaOaepProcess(key: publicKey, input: rawGroupKey, encrypt: true),
      ),
    });
  }
  await _postJson(
    signalingUri: signalingUri,
    path: '/api/groups/key-envelopes/update',
    body: {'token': session.token, 'groupId': groupId, 'envelopes': envelopes},
  );
}

Uint8List _rsaOaepProcess({
  required RSAAsymmetricKey key,
  required Uint8List input,
  required bool encrypt,
}) {
  final modulus = key.modulus!;
  final modulusLength = (modulus.bitLength + 7) ~/ 8;
  if (encrypt) {
    final publicKey = key as RSAPublicKey;
    final encoded = _oaepEncode(input, modulusLength);
    final encrypted = _bytesToBigInt(
      encoded,
    ).modPow(publicKey.publicExponent!, modulus);
    return _bigIntToBytes(encrypted, modulusLength);
  }

  final privateKey = key as RSAPrivateKey;
  final decrypted = _bytesToBigInt(
    input,
  ).modPow(privateKey.privateExponent!, modulus);
  return _oaepDecode(_bigIntToBytes(decrypted, modulusLength));
}

Uint8List _oaepEncode(Uint8List message, int encodedLength) {
  const hashLength = 32;
  if (message.length > encodedLength - (2 * hashLength) - 2) {
    throw StateError('RSA-OAEP message is too long.');
  }
  final labelHash = Uint8List.fromList(
    dart_crypto.sha256.convert(const <int>[]).bytes,
  );
  final dataBlock = Uint8List(encodedLength - hashLength - 1)
    ..setRange(0, hashLength, labelHash);
  final separator = dataBlock.length - message.length - 1;
  dataBlock[separator] = 1;
  dataBlock.setRange(separator + 1, dataBlock.length, message);
  final seed = _secureRandomBytes(hashLength);
  final dataMask = _mgf1(seed, dataBlock.length);
  final maskedData = _xorBytes(dataBlock, dataMask);
  final seedMask = _mgf1(maskedData, hashLength);
  final maskedSeed = _xorBytes(seed, seedMask);
  return Uint8List.fromList([0, ...maskedSeed, ...maskedData]);
}

Uint8List _oaepDecode(Uint8List encoded) {
  const hashLength = 32;
  if (encoded.length < (2 * hashLength) + 2 || encoded.first != 0) {
    throw StateError('RSA-OAEP payload was invalid.');
  }
  final maskedSeed = Uint8List.fromList(encoded.sublist(1, 1 + hashLength));
  final maskedData = Uint8List.fromList(encoded.sublist(1 + hashLength));
  final seed = _xorBytes(maskedSeed, _mgf1(maskedData, hashLength));
  final dataBlock = _xorBytes(maskedData, _mgf1(seed, maskedData.length));
  final expectedHash = dart_crypto.sha256.convert(const <int>[]).bytes;
  var mismatch = 0;
  for (var i = 0; i < hashLength; i++) {
    mismatch |= dataBlock[i] ^ expectedHash[i];
  }
  var separator = -1;
  for (var i = hashLength; i < dataBlock.length; i++) {
    if (dataBlock[i] == 1) {
      separator = i;
      break;
    }
    if (dataBlock[i] != 0) mismatch |= 1;
  }
  if (mismatch != 0 || separator < 0) {
    throw StateError('RSA-OAEP authentication failed.');
  }
  return Uint8List.fromList(dataBlock.sublist(separator + 1));
}

Uint8List _mgf1(Uint8List seed, int length) {
  final output = BytesBuilder(copy: false);
  for (var counter = 0; output.length < length; counter++) {
    final counterBytes = Uint8List(4)
      ..[0] = (counter >> 24) & 0xff
      ..[1] = (counter >> 16) & 0xff
      ..[2] = (counter >> 8) & 0xff
      ..[3] = counter & 0xff;
    output.add(dart_crypto.sha256.convert([...seed, ...counterBytes]).bytes);
  }
  return Uint8List.fromList(output.takeBytes().sublist(0, length));
}

Uint8List _xorBytes(List<int> first, List<int> second) => Uint8List.fromList(
  List<int>.generate(first.length, (index) => first[index] ^ second[index]),
);

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final output = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    output[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  if (remaining != BigInt.zero) {
    throw StateError('RSA integer does not fit the modulus.');
  }
  return output;
}

@visibleForTesting
Future<void> runNativeCryptoSelfTest() async {
  final pair = CryptoUtils.generateRSAKeyPair();
  final plaintext = _secureRandomBytes(32);
  final encrypted = _rsaOaepProcess(
    key: pair.publicKey as RSAPublicKey,
    input: plaintext,
    encrypt: true,
  );
  final decrypted = _rsaOaepProcess(
    key: pair.privateKey as RSAPrivateKey,
    input: encrypted,
    encrypt: false,
  );
  if (!_constantTimeEqual(plaintext, decrypted)) {
    throw StateError('RSA-OAEP self-test failed.');
  }

  final aesKey = SecretKey(_secureRandomBytes(32));
  final iv = _secureRandomBytes(12);
  final aesEncrypted = await _aesEncrypt(
    key: aesKey,
    plaintext: plaintext,
    iv: iv,
  );
  final aesDecrypted = await _aesDecrypt(
    key: aesKey,
    ciphertext: aesEncrypted,
    iv: iv,
  );
  if (!_constantTimeEqual(plaintext, aesDecrypted)) {
    throw StateError('AES-GCM self-test failed.');
  }

  // The platform ECDH implementation is registered only in a real Flutter
  // host. Unit tests use the Dart VM, where P-256 is deliberately unavailable.
  if (FlutterCryptography.isPluginPresent) {
    final ecdh = Ecdh.p256(length: 32);
    final first = await ecdh.newKeyPair();
    final second = await ecdh.newKeyPair();
    final firstPublic = await first.extractPublicKey();
    final secondPublic = await second.extractPublicKey();
    final firstSecret = await ecdh.sharedSecretKey(
      keyPair: first,
      remotePublicKey: secondPublic,
    );
    final secondSecret = await ecdh.sharedSecretKey(
      keyPair: second,
      remotePublicKey: firstPublic,
    );
    if (!_constantTimeEqual(
      await firstSecret.extractBytes(),
      await secondSecret.extractBytes(),
    )) {
      throw StateError('ECDH P-256 self-test failed.');
    }
  }
}

bool _constantTimeEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var i = 0; i < first.length; i++) {
    difference |= first[i] ^ second[i];
  }
  return difference == 0;
}

Uint8List _secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List _p256Coordinate(List<int> value) {
  if (value.length == 32) return Uint8List.fromList(value);
  if (value.length == 33 && value.first == 0) {
    return Uint8List.fromList(value.sublist(1));
  }
  if (value.length < 32) {
    return Uint8List.fromList([
      ...List<int>.filled(32 - value.length, 0),
      ...value,
    ]);
  }
  throw StateError('Unexpected P-256 coordinate length: ${value.length}.');
}

Uint8List _p256PlatformCoordinate(List<int> value) {
  final coordinate = _p256Coordinate(value);
  // cryptography_flutter passes coordinates to Java BigInteger(byte[]), which
  // is signed. Prefix a zero byte when the wire-format coordinate has its
  // high bit set so Java keeps it positive.
  if (coordinate.first & 0x80 == 0) return coordinate;
  return Uint8List.fromList([0, ...coordinate]);
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

  factory MailboxSummary.fromJson(Map<String, dynamic> json) => MailboxSummary(
    room: json['room'] as String,
    contactUsername: json['contactUsername'] as String,
    unreadCount: json['unreadCount'] as int,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as int) * 1000,
    ),
  );
}

const int _maxStoredMessages = 500;
const String _historyStoragePrefix = 'peep:history:';

String _historyStorageKey(String key) =>
    '$_historyStoragePrefix${key.trim().toLowerCase()}';
String _groupKeyStorageKey(String groupId) => 'peep:group-key:$groupId';

List<ChatMessage> loadMessageHistory(String conversationKey) {
  final raw = _preferences.getString(_historyStorageKey(conversationKey));
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List
        ? decoded
              .whereType<Map<String, dynamic>>()
              .map(_messageFromJson)
              .toList(growable: false)
        : const [];
  } catch (_) {
    return const [];
  }
}

void saveMessageHistory(String conversationKey, List<ChatMessage> messages) {
  var capped = messages.length > _maxStoredMessages
      ? messages.sublist(messages.length - _maxStoredMessages)
      : List<ChatMessage>.from(messages);
  final storageKey = _historyStorageKey(conversationKey);
  while (capped.isNotEmpty) {
    try {
      unawaited(
        _preferences.setString(
          storageKey,
          jsonEncode(capped.map(_messageToJson).toList(growable: false)),
        ),
      );
      return;
    } catch (_) {
      capped = capped.sublist(capped.length < 20 ? 1 : capped.length ~/ 4);
    }
  }
  unawaited(_preferences.remove(storageKey));
}

List<StoredConversation> listStoredDirectConversations(String username) {
  final normalized = username.trim().toLowerCase();
  final conversations = <StoredConversation>[];
  for (final storageKey in _preferences.keys) {
    if (!storageKey.startsWith(_historyStoragePrefix)) continue;
    final key = storageKey.substring(_historyStoragePrefix.length);
    final parts = key.split(':');
    if (parts.length != 3 || parts.first != 'dm') continue;
    if (parts[1] != normalized && parts[2] != normalized) continue;
    final messages = loadMessageHistory(key);
    if (messages.isEmpty) continue;
    final last = messages.last;
    conversations.add(
      StoredConversation(
        conversationKey: key,
        contactUsername: parts[1] == normalized ? parts[2] : parts[1],
        lastText: last.attachment?.name ?? last.text,
        updatedAt: last.sentAt,
      ),
    );
  }
  conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return conversations;
}

Map<String, dynamic> _messageToJson(ChatMessage message) => {
  'text': message.text,
  'isLocal': message.isLocal,
  'sentAt': message.sentAt.toIso8601String(),
  if (message.sender != null) 'sender': message.sender,
  if (message.attachment != null)
    'attachment': {
      'name': message.attachment!.name,
      'mimeType': message.attachment!.mimeType,
      'size': message.attachment!.size,
      'dataUrl': message.attachment!.dataUrl,
    },
};

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final attachmentJson = json['attachment'];
  return ChatMessage(
    text: json['text'] is String ? json['text'] as String : '',
    isLocal: json['isLocal'] == true,
    sentAt:
        DateTime.tryParse(json['sentAt'] as String? ?? '') ?? DateTime.now(),
    sender: json['sender'] as String?,
    attachment: attachmentJson is Map<String, dynamic>
        ? _attachmentFromJson(attachmentJson)
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
  return _registerAttachment(
    AttachmentData(
      name: name,
      mimeType: mimeType,
      size: size,
      dataUrl: dataUrl,
    ),
  );
}

AttachmentData _registerAttachment(AttachmentData attachment) {
  if (!attachment.isAudio && !attachment.isVideo) return attachment;
  final id = 'peep-native-attachment-${_nextNativeViewId++}';
  final registered = AttachmentData(
    name: attachment.name,
    mimeType: attachment.mimeType,
    size: attachment.size,
    dataUrl: attachment.dataUrl,
    viewType: id,
  );
  _attachmentViews[id] = registered;
  return registered;
}

String _directRoom(String first, String second) {
  final a = first.trim().toLowerCase();
  final b = second.trim().toLowerCase();
  return a.compareTo(b) <= 0 ? 'dm:$a:$b' : 'dm:$b:$a';
}

class _IncomingAttachment {
  _IncomingAttachment({
    required this.name,
    required this.mimeType,
    required this.size,
  });

  final String name;
  final String mimeType;
  final int size;
  final StringBuffer data = StringBuffer();
}

class _RemoteNativeView {
  const _RemoteNativeView({
    required this.title,
    required this.viewType,
    required this.renderer,
    required this.stream,
  });

  final String title;
  final String viewType;
  final RTCVideoRenderer renderer;
  final MediaStream stream;
}

class GroupClient {
  GroupClient({
    required this.onStatus,
    required this.onMessage,
    required this.onLog,
    required this.onMediaChanged,
  }) {
    _localViewType = 'peep-group-local-native-${_nextNativeViewId++}';
    _videoRenderers[_localViewType] = _localRenderer;
    unawaited(_localRenderer.initialize());
  }

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;
  final void Function() onMediaChanged;

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  late final String _localViewType;
  final Map<String, _RemoteNativeView> _remoteViews = {};
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  RTCPeerConnection? _publisherConnection;
  RTCPeerConnection? _subscriberConnection;
  MediaStream? _localStream;
  SecretKey? _groupKey;
  Uri? _conferenceSignalingUri;
  String? _conferenceToken;
  String? _conferenceGroupId;
  Timer? _conferenceRefreshTimer;
  bool _socketOpen = false;
  bool _closed = false;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  bool _screenShareEnabled = false;
  bool _conferenceRefreshQueued = false;
  CallState _callState = CallState.idle;

  bool get canSend => _socketOpen;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
  bool get screenShareEnabled => _screenShareEnabled;
  CallState get callState => _callState;
  bool get callActive => _callState != CallState.idle;
  String get localVideoViewType => _localViewType;
  String? get remoteVideoViewType =>
      _remoteViews.isEmpty ? null : _remoteViews.values.first.viewType;
  List<MediaView> get remoteVideoViews => _remoteViews.values
      .map((view) => MediaView(title: view.title, viewType: view.viewType))
      .toList(growable: false);

  Future<void> connect({
    required Uri signalingUri,
    required String token,
    required String groupId,
    required String groupKeyBase64,
  }) async {
    await disconnect();
    _closed = false;
    _groupKey = SecretKey(base64Decode(groupKeyBase64));
    onStatus(PeerStatus.signaling);
    await _connectSocket(
      signalingUri.replace(
        queryParameters: {
          ...signalingUri.queryParameters,
          'token': token,
          'group': groupId,
        },
      ),
    );
  }

  void send(String text) {
    if (!_socketOpen) {
      onLog('Group socket is not open.');
      return;
    }
    unawaited(_sendEncrypted({'kind': 'group-chat', 'body': text}));
    onMessage(ChatMessage(text: text, isLocal: true, sentAt: DateTime.now()));
  }

  Future<void> startConference({
    required Uri signalingUri,
    required String token,
    required String groupId,
  }) async {
    if (!_socketOpen) {
      onLog('Open the group chat before starting a group call.');
      return;
    }
    if (_callState != CallState.idle) return;
    _conferenceSignalingUri = signalingUri;
    _conferenceToken = token;
    _conferenceGroupId = groupId;
    _callState = CallState.outgoing;
    onMediaChanged();
    try {
      final conference = await _postJson(
        signalingUri: signalingUri,
        path: '/api/groups/conference/start',
        body: {'token': token, 'groupId': groupId},
      );
      if (conference['mode'] is String) {
        onLog('Group conference mode: ${conference['mode']}.');
      }
      await _ensureLocalMedia(audio: true, video: false);
      await _joinPublisher();
      await _joinSubscriber();
      _publishConferenceRefresh();
      _callState = CallState.active;
      onLog('Group call started.');
      onMediaChanged();
    } catch (error) {
      await _stopConferenceMedia(notifyServer: true);
      onLog('Could not start group call: $error');
    }
  }

  Future<void> endConference() async {
    if (_callState == CallState.idle) return;
    await _stopConferenceMedia(notifyServer: true);
    onLog('Group call ended.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
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
          await _stopScreenShareService();
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
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
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
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Microphone enabled.' : 'Microphone muted.');
    onMediaChanged();
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a group call before sharing your screen.');
      return;
    }
    if (!enabled) {
      final stopped = _stopLocalVideoTracks();
      _screenShareEnabled = false;
      _cameraEnabled = false;
      await _stopScreenShareService();
      if (stopped) {
        await _joinPublisher();
        _publishConferenceRefresh();
      }
      onLog('Screen sharing stopped.');
      onMediaChanged();
      return;
    }
    try {
      await _startScreenShareService();
      _stopLocalVideoTracks();
      final screen = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });
      _localStream ??= await createLocalMediaStream('peep-group-local');
      for (final track in screen.getVideoTracks()) {
        await _localStream!.addTrack(track);
        track.onEnded = () {
          if (_screenShareEnabled) unawaited(setScreenShareEnabled(false));
        };
      }
      _localRenderer.srcObject = _localStream;
      _screenShareEnabled = true;
      _cameraEnabled = false;
      await _joinPublisher();
      _publishConferenceRefresh();
      onLog('Screen sharing started.');
      onMediaChanged();
    } catch (error) {
      _screenShareEnabled = false;
      await _stopScreenShareService();
      onLog('Could not share screen: $error');
      onMediaChanged();
    }
  }

  Future<void> disconnect() async {
    _closed = true;
    await _stopConferenceMedia(notifyServer: true);
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    _socketSubscription = null;
    _socket = null;
    _socketOpen = false;
    _groupKey = null;
    onStatus(PeerStatus.disconnected);
  }

  Future<void> _connectSocket(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    _socket = channel;
    await channel.ready.timeout(const Duration(seconds: 8));
    _socketOpen = true;
    onLog('Group signaling connected.');
    _socketSubscription = channel.stream.listen(
      (data) {
        if (data is String) _handleSignal(data);
      },
      onError: (Object error, StackTrace stack) {
        _socketOpen = false;
        onStatus(PeerStatus.failed);
        onLog('Group socket error: $error');
      },
      onDone: () {
        _socketOpen = false;
        if (!_closed) onStatus(PeerStatus.disconnected);
        onLog('Group signaling disconnected.');
      },
    );
  }

  Future<void> _sendEncrypted(Map<String, dynamic> payload) async {
    final key = _groupKey;
    if (key == null || !_socketOpen) return;
    final iv = _secureRandomBytes(12);
    final encrypted = await _aesEncrypt(
      key: key,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      iv: iv,
    );
    _socket!.sink.add(
      jsonEncode({
        'type': 'group-e2ee',
        'payload': {
          'iv': base64Encode(iv),
          'ciphertext': base64Encode(encrypted),
        },
      }),
    );
  }

  void _handleSignal(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      switch (decoded['type']) {
        case 'welcome':
          onStatus(PeerStatus.connected);
          onLog('Joined group.');
        case 'presence':
          onLog('Group peer ${decoded['peer']} ${decoded['event']}.');
        case 'group-chat':
          if (decoded['body'] is String) {
            onMessage(
              ChatMessage(
                text: decoded['body'] as String,
                isLocal: false,
                sentAt: DateTime.now(),
                sender: decoded['from'] as String?,
              ),
            );
          }
        case 'group-e2ee':
          unawaited(_handleEncryptedGroupPayload(decoded));
        case 'conference-refresh':
          if (_callState == CallState.active) _scheduleConferenceRefresh();
        case 'error':
          onStatus(PeerStatus.failed);
          onLog('${decoded['message'] ?? 'Group signaling error.'}');
      }
    } catch (error) {
      onStatus(PeerStatus.failed);
      onLog('Group signal handling failed: $error');
    }
  }

  Future<void> _handleEncryptedGroupPayload(
    Map<String, dynamic> decoded,
  ) async {
    final payload = decoded['payload'];
    final key = _groupKey;
    if (payload is! Map<String, dynamic> || key == null) return;
    if (payload['iv'] is! String || payload['ciphertext'] is! String) return;
    try {
      final plaintext = await _aesDecrypt(
        key: key,
        ciphertext: Uint8List.fromList(
          base64Decode(payload['ciphertext'] as String),
        ),
        iv: Uint8List.fromList(base64Decode(payload['iv'] as String)),
      );
      final appPayload = jsonDecode(utf8.decode(plaintext));
      if (appPayload is Map<String, dynamic> &&
          appPayload['kind'] == 'group-chat' &&
          appPayload['body'] is String) {
        onMessage(
          ChatMessage(
            text: appPayload['body'] as String,
            isLocal: false,
            sentAt: DateTime.now(),
            sender: decoded['from'] as String?,
          ),
        );
      }
    } catch (error) {
      onLog('Could not decrypt group message: $error');
    }
  }

  Future<void> _ensureLocalMedia({
    required bool audio,
    required bool video,
  }) async {
    final needsAudio = audio && _localStream?.getAudioTracks().isEmpty != false;
    final needsVideo = video && _localStream?.getVideoTracks().isEmpty != false;
    if (!needsAudio && !needsVideo) return;
    await _requestMediaPermissions(audio: needsAudio, video: needsVideo);
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': needsAudio,
      'video': needsVideo
          ? {'width': 1280, 'height': 720, 'facingMode': 'user'}
          : false,
    });
    _localStream ??= await createLocalMediaStream('peep-group-local');
    for (final track in stream.getTracks()) {
      await _localStream!.addTrack(track);
    }
    _localRenderer.srcObject = _localStream;
    _cameraEnabled = _localStream!.getVideoTracks().any((t) => t.enabled);
    _microphoneEnabled = _localStream!.getAudioTracks().any((t) => t.enabled);
    onMediaChanged();
  }

  bool _stopLocalVideoTracks() {
    final tracks = List<MediaStreamTrack>.from(
      _localStream?.getVideoTracks() ?? const [],
    );
    for (final track in tracks) {
      track.stop();
      _localStream?.removeTrack(track);
    }
    _localRenderer.srcObject = _localStream;
    return tracks.isNotEmpty;
  }

  Future<void> _joinPublisher() async {
    final pc = await _newSfuConnection('publisher');
    await _publisherConnection?.close();
    _publisherConnection = pc;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(track, _localStream!);
    }
    await _negotiateSfu(role: 'publisher', connection: pc);
  }

  Future<void> _joinSubscriber() async {
    final pc = await _newSfuConnection('subscriber');
    await _subscriberConnection?.close();
    await _clearRemoteViews();
    _subscriberConnection = pc;
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await _negotiateSfu(role: 'subscriber', connection: pc);
  }

  Future<RTCPeerConnection> _newSfuConnection(String label) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onStatus(PeerStatus.connected);
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
        onStatus(PeerStatus.connecting);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onStatus(PeerStatus.failed);
      }
    };
    pc.onIceConnectionState = (state) =>
        onLog('Group call $label ICE state: $state');
    pc.onTrack = (event) {
      if (event.track.kind == 'audio') return;
      unawaited(_attachRemoteGroupTrack(event));
    };
    return pc;
  }

  Future<void> _attachRemoteGroupTrack(RTCTrackEvent event) async {
    final stream = event.streams.isNotEmpty
        ? event.streams.first
        : await createLocalMediaStream('peep-group-remote');
    if (event.streams.isEmpty) await stream.addTrack(event.track);
    final streamId = stream.id.isEmpty
        ? 'remote-${_nextNativeViewId++}'
        : stream.id;
    var view = _remoteViews[streamId];
    if (view == null) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      final viewType = 'peep-group-remote-native-${_nextNativeViewId++}';
      renderer.srcObject = stream;
      _videoRenderers[viewType] = renderer;
      view = _RemoteNativeView(
        title: _remoteTitleForStream(streamId),
        viewType: viewType,
        renderer: renderer,
        stream: stream,
      );
      _remoteViews[streamId] = view;
    } else {
      view.renderer.srcObject = stream;
    }
    onLog('Group remote ${event.track.kind} track received.');
    onMediaChanged();
  }

  String _remoteTitleForStream(String id) {
    if (id.startsWith('sfu-')) {
      final separator = id.lastIndexOf('-');
      if (separator > 0 && separator < id.length - 1) {
        return id.substring(separator + 1);
      }
    }
    return 'Remote';
  }

  Future<void> _negotiateSfu({
    required String role,
    required RTCPeerConnection connection,
  }) async {
    final uri = _conferenceSignalingUri;
    final token = _conferenceToken;
    final groupId = _conferenceGroupId;
    if (uri == null || token == null || groupId == null) {
      throw StateError('Group conference is not initialized.');
    }
    final offer = await connection.createOffer();
    await connection.setLocalDescription(offer);
    await _waitForIceGatheringComplete(connection);
    final local = await connection.getLocalDescription();
    final decoded = await _postJson(
      signalingUri: uri,
      path: '/api/groups/sfu/join',
      body: {
        'token': token,
        'groupId': groupId,
        'role': role,
        'offer': {'type': local?.type, 'sdp': local?.sdp},
      },
    );
    final answer = decoded['answer'];
    if (answer is! Map<String, dynamic>) {
      throw StateError('SFU answer was invalid.');
    }
    await connection.setRemoteDescription(
      RTCSessionDescription(
        answer['sdp'] as String?,
        answer['type'] as String?,
      ),
    );
  }

  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (pc.iceGatheringState !=
            RTCIceGatheringState.RTCIceGatheringStateComplete &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _publishConferenceRefresh() {
    if (_socketOpen) {
      _socket!.sink.add(jsonEncode({'type': 'conference-refresh'}));
    }
  }

  void _scheduleConferenceRefresh() {
    if (_conferenceRefreshQueued) return;
    _conferenceRefreshQueued = true;
    _conferenceRefreshTimer?.cancel();
    _conferenceRefreshTimer = Timer(const Duration(milliseconds: 900), () {
      _conferenceRefreshQueued = false;
      if (_callState == CallState.active) unawaited(_refreshConference());
    });
  }

  Future<void> _refreshConference() async {
    try {
      await _joinSubscriber();
      onMediaChanged();
    } catch (error) {
      onLog('Could not refresh group call: $error');
    }
  }

  Future<void> _clearRemoteViews() async {
    for (final view in _remoteViews.values) {
      for (final track in view.stream.getTracks()) {
        track.stop();
      }
      _videoRenderers.remove(view.viewType);
      view.renderer.srcObject = null;
      await view.renderer.dispose();
    }
    _remoteViews.clear();
  }

  Future<void> _stopConferenceMedia({required bool notifyServer}) async {
    final wasScreenSharing = _screenShareEnabled;
    _conferenceRefreshTimer?.cancel();
    _conferenceRefreshTimer = null;
    _conferenceRefreshQueued = false;
    await _publisherConnection?.close();
    await _subscriberConnection?.close();
    _publisherConnection = null;
    _subscriberConnection = null;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _clearRemoteViews();
    _localStream = null;
    _localRenderer.srcObject = null;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    if (wasScreenSharing) await _stopScreenShareService();
    _callState = CallState.idle;
    final uri = _conferenceSignalingUri;
    final token = _conferenceToken;
    final groupId = _conferenceGroupId;
    if (notifyServer && uri != null && token != null && groupId != null) {
      try {
        for (final role in const ['publisher', 'subscriber']) {
          await _postJson(
            signalingUri: uri,
            path: '/api/groups/sfu/leave',
            body: {'token': token, 'groupId': groupId, 'role': role},
          );
        }
        await _postJson(
          signalingUri: uri,
          path: '/api/groups/conference/end',
          body: {'token': token, 'groupId': groupId},
        );
      } catch (error) {
        onLog('Could not close group call session: $error');
      }
    }
    _conferenceSignalingUri = null;
    _conferenceToken = null;
    _conferenceGroupId = null;
    onMediaChanged();
  }
}

class PeerClient {
  PeerClient({
    required this.onStatus,
    required this.onMessage,
    required this.onLog,
    required this.onMediaChanged,
  }) {
    final id = _nextNativeViewId++;
    _localViewType = 'peep-local-native-$id';
    _remoteViewType = 'peep-remote-native-$id';
    _videoRenderers[_localViewType] = _localRenderer;
    _videoRenderers[_remoteViewType] = _remoteRenderer;
    unawaited(_localRenderer.initialize());
    unawaited(_remoteRenderer.initialize());
  }

  final void Function(PeerStatus status) onStatus;
  final void Function(ChatMessage message) onMessage;
  final void Function(String message) onLog;
  final void Function() onMediaChanged;

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  late final String _localViewType;
  late final String _remoteViewType;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final List<Map<String, dynamic>> _pendingCandidates = [];
  final List<String> _pendingMessages = [];
  final List<Map<String, dynamic>> _pendingEncryptedPayloads = [];
  final Map<String, _IncomingAttachment> _incomingAttachments = {};
  EcKeyPair? _privateKey;
  SecretKey? _aesKey;
  String? _e2eePublicKey;
  Map<String, dynamic>? _pendingEncryptionKey;
  bool _encryptionHandshakeStarted = false;
  String? _roomKeyStorageKey;
  bool _socketOpen = false;
  bool _remoteDescriptionSet = false;
  bool _offerStarted = false;
  bool _closed = false;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  bool _screenShareEnabled = false;
  CallState _callState = CallState.idle;
  // The encrypted JSON envelope expands each chunk substantially (JSON +
  // AES-GCM tag + base64). Keep the source chunk comfortably below mobile
  // WebRTC/SCTP message limits so an attachment cannot tear down the channel.
  static const int _attachmentChunkSize = 4 * 1024;

  bool get canSend =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
  bool get canStoreOffline => _socketOpen && encryptionReady;
  bool get canMessage => canSend || canStoreOffline;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
  bool get screenShareEnabled => _screenShareEnabled;
  bool get encryptionReady => _aesKey != null;
  CallState get callState => _callState;
  bool get callActive => _callState != CallState.idle;
  String get localVideoViewType => _localViewType;
  String get remoteVideoViewType => _remoteViewType;

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
    String? authToken,
    String? accountUsername,
    String? contactUsername,
  }) async {
    await disconnect();
    _closed = false;
    _remoteDescriptionSet = false;
    _offerStarted = false;
    _pendingCandidates.clear();
    _pendingMessages.clear();
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _pendingEncryptionKey = null;
    _encryptionHandshakeStarted = false;
    _e2eePublicKey = null;
    final effectiveRoom = accountUsername != null && contactUsername != null
        ? _directRoom(accountUsername, contactUsername)
        : room.trim();
    _roomKeyStorageKey = 'peep:e2ee-room:$effectiveRoom';
    await _loadPersistedRoomKey();
    onStatus(PeerStatus.signaling);
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    _wirePeerConnection();
    _peerConnection!.onDataChannel = _attachDataChannel;
    final url = signalingUri.replace(
      queryParameters: {
        ...signalingUri.queryParameters,
        if (authToken != null && contactUsername != null) ...{
          'token': authToken,
          'contact': contactUsername,
        } else ...{
          'room': room,
          'peer': peerId,
        },
      },
    );
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
    final result = await fp.FilePicker.platform.pickFiles(
      type: fp.FileType.media,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) {
      onLog('Could not read attachment.');
      return;
    }
    final mimeType =
        lookupMimeType(file.name, headerBytes: bytes) ??
        'application/octet-stream';
    if (!mimeType.startsWith('audio/') && !mimeType.startsWith('video/')) {
      onLog('Choose an audio or video file.');
      return;
    }
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final attachment = _registerAttachment(
      AttachmentData(
        name: file.name,
        mimeType: mimeType,
        size: bytes.length,
        dataUrl: dataUrl,
      ),
    );
    onMessage(
      ChatMessage(
        text: file.name,
        isLocal: true,
        sentAt: DateTime.now(),
        attachment: attachment,
      ),
    );
    await _sendAttachment(attachment);
  }

  void startCall() {
    if (!canSend) {
      onLog('Wait for the chat connection before starting a call.');
      return;
    }
    if (_callState != CallState.idle) return;
    _callState = CallState.outgoing;
    unawaited(_sendControl({'kind': 'call-request'}));
    onLog('Call request sent.');
    onMediaChanged();
  }

  Future<void> acceptCall() async {
    if (_callState != CallState.incoming) return;
    try {
      _callState = CallState.active;
      await _sendControl({'kind': 'call-accept'});
      // Send the acceptance over the already-open data channel before adding
      // media tracks. Adding tracks triggers SDP renegotiation on Android;
      // doing it first could strand the caller in the outgoing state.
      onLog('Call accepted. Waiting for caller media offer.');
      onMediaChanged();
    } catch (error) {
      _callState = CallState.idle;
      await _sendControl({'kind': 'call-decline'});
      onLog('Could not start microphone: $error');
      onMediaChanged();
    }
  }

  void declineCall() {
    if (_callState != CallState.incoming) return;
    _callState = CallState.idle;
    unawaited(_sendControl({'kind': 'call-decline'}));
    onLog('Call declined.');
    onMediaChanged();
  }

  Future<void> endCall() async {
    if (_callState == CallState.idle) return;
    await _sendControl({'kind': 'call-end'});
    await _stopCallMedia();
    onLog('Call ended.');
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a call before turning on video.');
      return;
    }
    if (enabled &&
        (_screenShareEnabled ||
            _localStream?.getVideoTracks().isEmpty != false)) {
      try {
        if (_screenShareEnabled) {
          _stopLocalVideoTracks();
          await _stopScreenShareService();
        }
        _screenShareEnabled = false;
        await _startLocalMedia(
          audio: _localStream?.getAudioTracks().isEmpty != false,
          video: true,
        );
        await _createAndSendOffer();
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
      if (stopped) await _createAndSendOffer();
      onLog('Camera turned off.');
      onMediaChanged();
      return;
    }
    _cameraEnabled = enabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
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
        await _startLocalMedia(audio: true, video: false);
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
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    onLog(enabled ? 'Microphone enabled.' : 'Microphone muted.');
    onMediaChanged();
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    if (_callState != CallState.active) {
      onLog('Start a call before sharing your screen.');
      return;
    }
    if (!enabled) {
      final stopped = _stopLocalVideoTracks();
      _screenShareEnabled = false;
      _cameraEnabled = false;
      await _stopScreenShareService();
      if (stopped) await _createAndSendOffer();
      onLog('Screen sharing stopped.');
      onMediaChanged();
      return;
    }
    try {
      await _startScreenShareService();
      _stopLocalVideoTracks();
      final screen = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });
      _localStream ??= await createLocalMediaStream('peep-local');
      for (final track in screen.getVideoTracks()) {
        await _localStream!.addTrack(track);
        await _peerConnection!.addTrack(track, _localStream!);
        track.onEnded = () {
          if (_screenShareEnabled) unawaited(setScreenShareEnabled(false));
        };
      }
      _localRenderer.srcObject = _localStream;
      _screenShareEnabled = true;
      _cameraEnabled = false;
      await _createAndSendOffer();
      onLog('Screen sharing started.');
      onMediaChanged();
    } catch (error) {
      _screenShareEnabled = false;
      await _stopScreenShareService();
      onLog('Could not share screen: $error');
      onMediaChanged();
    }
  }

  Future<void> disconnect() async {
    _closed = true;
    final wasScreenSharing = _screenShareEnabled;
    await _dataChannel?.close();
    await _peerConnection?.close();
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    for (final track in _remoteStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    _dataChannel = null;
    _peerConnection = null;
    _socketSubscription = null;
    _socket = null;
    _socketOpen = false;
    _localStream = null;
    _remoteStream = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    if (wasScreenSharing) await _stopScreenShareService();
    _callState = CallState.idle;
    _pendingMessages.clear();
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _privateKey = null;
    _aesKey = null;
    _e2eePublicKey = null;
    _pendingEncryptionKey = null;
    _encryptionHandshakeStarted = false;
    _roomKeyStorageKey = null;
    onStatus(PeerStatus.disconnected);
    onMediaChanged();
  }

  void _wirePeerConnection() {
    final pc = _peerConnection!;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _sendSignal({'type': 'candidate', 'candidate': candidate.toMap()});
    };
    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onStatus(PeerStatus.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          onStatus(PeerStatus.connecting);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          onStatus(PeerStatus.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (!_closed) onStatus(PeerStatus.disconnected);
        default:
          break;
      }
    };
    pc.onIceConnectionState = (state) => onLog('ICE state: $state');
    pc.onTrack = (event) {
      unawaited(_attachRemoteTrack(event));
    };
  }

  Future<void> _attachRemoteTrack(RTCTrackEvent event) async {
    final stream = event.streams.isNotEmpty
        ? event.streams.first
        : _remoteStream ?? await createLocalMediaStream('peep-remote');
    if (event.streams.isEmpty) await stream.addTrack(event.track);
    _remoteStream = stream;
    _remoteRenderer.srcObject = stream;
    onLog('Remote ${event.track.kind} track received.');
    onMediaChanged();
  }

  Future<void> _startLocalMedia({
    required bool audio,
    required bool video,
  }) async {
    if (!audio && !video) return;
    await _requestMediaPermissions(audio: audio, video: video);
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': audio,
      'video': video
          ? {'width': 1280, 'height': 720, 'facingMode': 'user'}
          : false,
    });
    _localStream ??= await createLocalMediaStream('peep-local');
    for (final track in stream.getTracks()) {
      final alreadyPresent = _localStream!.getTracks().any(
        (current) => current.id == track.id,
      );
      if (!alreadyPresent) {
        await _localStream!.addTrack(track);
        await _peerConnection!.addTrack(track, _localStream!);
      }
    }
    _localRenderer.srcObject = _localStream;
    _cameraEnabled = _localStream!.getVideoTracks().any((t) => t.enabled);
    _microphoneEnabled = _localStream!.getAudioTracks().any((t) => t.enabled);
    onMediaChanged();
  }

  bool _stopLocalVideoTracks() {
    final tracks = List<MediaStreamTrack>.from(
      _localStream?.getVideoTracks() ?? const [],
    );
    for (final track in tracks) {
      track.stop();
      _localStream?.removeTrack(track);
    }
    _localRenderer.srcObject = _localStream;
    return tracks.isNotEmpty;
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        unawaited(_handleDataChannelOpen());
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (!_closed) {
          _dataChannel = null;
          onStatus(PeerStatus.waitingForPeer);
          onMediaChanged();
        }
      }
    };
    channel.onMessage = (message) {
      if (!message.isBinary) _handleDataChannelMessage(message.text);
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(_handleDataChannelOpen());
    }
  }

  Future<void> _handleDataChannelOpen() async {
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
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['kind'] == 'e2ee-key') {
        unawaited(_handleEncryptionKey(decoded));
      } else if (decoded['kind'] == 'e2ee') {
        unawaited(_handleEncryptedPayload(decoded));
      } else {
        onLog('Ignored unencrypted data-channel payload.');
      }
    } catch (_) {
      onLog('Ignored unreadable data-channel payload.');
    }
  }

  void _handleAppPayload(Map<String, dynamic> decoded) {
    switch (decoded['kind']) {
      case 'chat':
        if (decoded['text'] is String) {
          onMessage(
            ChatMessage(
              text: decoded['text'] as String,
              isLocal: false,
              sentAt: DateTime.now(),
            ),
          );
        }
      case 'attachment-start':
        _handleAttachmentStart(decoded);
      case 'attachment-chunk':
        _handleAttachmentChunk(decoded);
      case 'attachment-end':
        _handleAttachmentEnd(decoded);
      case 'call-request':
        if (_callState == CallState.idle) {
          _callState = CallState.incoming;
          onLog('Incoming call request.');
          onMediaChanged();
        } else {
          unawaited(_sendControl({'kind': 'call-decline'}));
        }
      case 'call-accept':
        unawaited(_handleCallAccepted());
      case 'call-decline':
        if (_callState == CallState.outgoing) {
          _callState = CallState.idle;
          onLog('Call declined.');
          onMediaChanged();
        }
      case 'call-end':
        unawaited(_stopCallMedia());
        onLog('Peer ended the call.');
    }
  }

  Future<void> _handleCallAccepted() async {
    if (_callState != CallState.outgoing) return;
    try {
      await _startLocalMedia(audio: true, video: false);
      _callState = CallState.active;
      onLog('Call accepted. Starting audio.');
      onMediaChanged();
      await _createAndSendOffer();
    } catch (error) {
      _callState = CallState.idle;
      await _sendControl({'kind': 'call-end'});
      onLog('Could not start microphone: $error');
      onMediaChanged();
    }
  }

  Future<void> _stopCallMedia() async {
    final wasScreenSharing = _screenShareEnabled;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    for (final track in _remoteStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    _localStream = null;
    _remoteStream = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _screenShareEnabled = false;
    if (wasScreenSharing) await _stopScreenShareService();
    _callState = CallState.idle;
    onMediaChanged();
  }

  void _flushPendingMessages() {
    if (!canSend) return;
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

  Future<void> _sendAttachment(AttachmentData attachment) async {
    final id = 'attachment-${DateTime.now().microsecondsSinceEpoch}';
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
      final end = min(offset + _attachmentChunkSize, attachment.dataUrl.length);
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
    if (message['id'] is! String ||
        message['name'] is! String ||
        message['mimeType'] is! String ||
        message['size'] is! int) {
      return;
    }
    _incomingAttachments[message['id'] as String] = _IncomingAttachment(
      name: message['name'] as String,
      mimeType: message['mimeType'] as String,
      size: message['size'] as int,
    );
    onLog('Receiving attachment: ${message['name']}.');
  }

  void _handleAttachmentChunk(Map<String, dynamic> message) {
    final id = message['id'];
    final data = message['data'];
    if (id is String && data is String) {
      _incomingAttachments[id]?.data.write(data);
    }
  }

  void _handleAttachmentEnd(Map<String, dynamic> message) {
    final id = message['id'];
    if (id is! String) return;
    final incoming = _incomingAttachments.remove(id);
    if (incoming == null) return;
    final attachment = _registerAttachment(
      AttachmentData(
        name: incoming.name,
        mimeType: incoming.mimeType,
        size: incoming.size,
        dataUrl: incoming.data.toString(),
      ),
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

  Future<void> _sendControl(Map<String, dynamic> message) async {
    final key = _aesKey;
    if (key == null) {
      _pendingEncryptedPayloads.add(message);
      onLog('Queued encrypted payload until E2EE is ready.');
      return;
    }
    final iv = _secureRandomBytes(12);
    final ciphertext = await _aesEncrypt(
      key: key,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(message))),
      iv: iv,
    );
    final envelope = {
      'kind': 'e2ee',
      'iv': base64Encode(iv),
      'ciphertext': base64Encode(ciphertext),
    };
    if (canSend) {
      await _dataChannel!.send(RTCDataChannelMessage(jsonEncode(envelope)));
    } else if (canStoreOffline) {
      _socket!.sink.add(jsonEncode({'type': 'store', 'payload': envelope}));
      onLog('Stored encrypted payload for offline delivery.');
    } else {
      onLog('No encrypted transport or offline mailbox is available.');
    }
  }

  Future<void> _startEncryptionHandshake() async {
    if (_encryptionHandshakeStarted) return;
    _encryptionHandshakeStarted = true;
    final ecdh = Ecdh.p256(length: 32);
    _privateKey = await ecdh.newKeyPair();
    final public = await _privateKey!.extractPublicKey();
    final rawPublic = Uint8List.fromList([
      0x04,
      ..._p256Coordinate(public.x),
      ..._p256Coordinate(public.y),
    ]);
    _e2eePublicKey = base64Encode(rawPublic);
    await _sendE2eePublicKey();
    onLog('E2EE key sent.');
    _retryE2eePublicKey(_e2eePublicKey!);

    final pendingKey = _pendingEncryptionKey;
    _pendingEncryptionKey = null;
    if (pendingKey != null) {
      await _handleEncryptionKey(pendingKey);
    }
  }

  Future<void> _sendE2eePublicKey() async {
    final publicKey = _e2eePublicKey;
    if (publicKey == null || !canSend) return;
    await _dataChannel!.send(
      RTCDataChannelMessage(
        jsonEncode({'kind': 'e2ee-key', 'publicKey': publicKey}),
      ),
    );
  }

  void _retryE2eePublicKey(String publicKey) {
    for (final delay in const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 750),
      Duration(milliseconds: 1500),
    ]) {
      unawaited(
        Future<void>.delayed(delay, () async {
          if (!_closed && _e2eePublicKey == publicKey) {
            await _sendE2eePublicKey();
          }
        }),
      );
    }
  }

  Future<void> _handleEncryptionKey(Map<String, dynamic> message) async {
    final encoded = message['publicKey'];
    final privateKey = _privateKey;
    if (encoded is! String || _aesKey != null) return;
    if (privateKey == null) {
      _pendingEncryptionKey = Map<String, dynamic>.from(message);
      onLog('Received E2EE key before local key generation completed.');
      return;
    }
    final raw = base64Decode(encoded);
    if (raw.length != 65 || raw.first != 0x04) {
      throw StateError('Peer E2EE public key was invalid.');
    }
    final remote = EcPublicKey(
      x: _p256PlatformCoordinate(raw.sublist(1, 33)),
      y: _p256PlatformCoordinate(raw.sublist(33, 65)),
      type: KeyPairType.p256,
    );
    _aesKey = await Ecdh.p256(
      length: 32,
    ).sharedSecretKey(keyPair: privateKey, remotePublicKey: remote);
    await _persistRoomKey();
    // The peer may have opened the channel after our first key was sent.
    // Reply once after deriving so it can finish the handshake too.
    await _sendE2eePublicKey();
    onLog('E2EE ready.');
    onMediaChanged();
    await _flushPendingEncryptedPayloads();
  }

  Future<void> _handleEncryptedPayload(Map<String, dynamic> message) async {
    final key = _aesKey;
    if (key == null ||
        message['iv'] is! String ||
        message['ciphertext'] is! String) {
      return;
    }
    try {
      final plaintext = await _aesDecrypt(
        key: key,
        ciphertext: Uint8List.fromList(
          base64Decode(message['ciphertext'] as String),
        ),
        iv: Uint8List.fromList(base64Decode(message['iv'] as String)),
      );
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is Map<String, dynamic>) _handleAppPayload(decoded);
    } catch (error) {
      onLog('Could not decrypt payload: $error');
    }
  }

  Future<void> _flushPendingEncryptedPayloads() async {
    if (!encryptionReady) return;
    final payloads = List<Map<String, dynamic>>.from(_pendingEncryptedPayloads);
    _pendingEncryptedPayloads.clear();
    for (final payload in payloads) {
      await _sendControl(payload);
    }
  }

  Future<void> _loadPersistedRoomKey() async {
    final storageKey = _roomKeyStorageKey;
    if (storageKey == null) return;
    final encoded = _preferences.getString(storageKey);
    if (encoded?.isNotEmpty == true) {
      try {
        _aesKey = SecretKey(base64Decode(encoded!));
        onLog('Loaded saved E2EE room key.');
        onMediaChanged();
      } catch (error) {
        await _preferences.remove(storageKey);
        onLog('Saved E2EE room key could not be loaded: $error');
      }
    }
  }

  Future<void> _persistRoomKey() async {
    final storageKey = _roomKeyStorageKey;
    final key = _aesKey;
    if (storageKey == null || key == null) return;
    await _preferences.setString(
      storageKey,
      base64Encode(await key.extractBytes()),
    );
  }

  Future<void> _connectSocket(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    _socket = channel;
    await channel.ready.timeout(const Duration(seconds: 8));
    _socketOpen = true;
    onLog('Signaling connected.');
    _socketSubscription = channel.stream.listen(
      (data) {
        if (data is String) unawaited(_handleSignal(data));
      },
      onError: (Object error, StackTrace stack) {
        _socketOpen = false;
        onStatus(PeerStatus.failed);
        onLog('Signaling socket error: $error');
      },
      onDone: () {
        _socketOpen = false;
        if (!_closed) onStatus(PeerStatus.disconnected);
        onLog('Signaling disconnected.');
      },
    );
  }

  Future<void> _handleSignal(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      switch (decoded['type']) {
        case 'welcome':
          await _handleWelcome(decoded);
        case 'presence':
          if (decoded['event'] == 'left') {
            _dataChannel = null;
            onStatus(PeerStatus.waitingForPeer);
            onMediaChanged();
          }
          onLog('Peer ${decoded['peer']} ${decoded['event']}.');
        case 'stored':
          if (decoded['payload'] is Map<String, dynamic>) {
            await _handleEncryptedPayload(
              decoded['payload'] as Map<String, dynamic>,
            );
          }
        case 'error':
          onStatus(PeerStatus.failed);
          onLog('${decoded['message'] ?? 'Signaling error.'}');
        case 'offer':
          await _handleOffer(decoded);
        case 'answer':
          await _handleAnswer(decoded);
        case 'candidate':
          await _handleCandidate(decoded);
      }
    } catch (error) {
      onStatus(PeerStatus.failed);
      onLog('Signal handling failed: $error');
    }
  }

  Future<void> _handleWelcome(Map<String, dynamic> signal) async {
    if (signal['existingPeers'] is int &&
        (signal['existingPeers'] as int) > 0) {
      onLog('Room already has a peer. Starting WebRTC offer.');
      await _createAndSendOffer(ensureDataChannel: true);
    } else {
      onStatus(PeerStatus.waitingForPeer);
      onLog('Waiting for another peer in this room.');
    }
  }

  Future<void> _createAndSendOffer({bool ensureDataChannel = false}) async {
    if (ensureDataChannel && _offerStarted) return;
    if (ensureDataChannel) _offerStarted = true;
    onStatus(PeerStatus.connecting);
    if (ensureDataChannel && _dataChannel == null) {
      _attachDataChannel(
        await _peerConnection!.createDataChannel('chat', RTCDataChannelInit()),
      );
    }
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _sendSignal({'type': 'offer', 'description': offer.toMap()});
  }

  Future<void> _handleOffer(Map<String, dynamic> signal) async {
    final description = signal['description'];
    if (description is! Map<String, dynamic>) return;
    onStatus(PeerStatus.connecting);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
        description['sdp'] as String?,
        description['type'] as String?,
      ),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    // For an accepted incoming call, add our microphone before creating the
    // answer so the caller's offer receives a bidirectional audio answer.
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
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _sendSignal({'type': 'answer', 'description': answer.toMap()});
  }

  Future<void> _handleAnswer(Map<String, dynamic> signal) async {
    final description = signal['description'];
    if (description is! Map<String, dynamic>) return;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
        description['sdp'] as String?,
        description['type'] as String?,
      ),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
  }

  Future<void> _handleCandidate(Map<String, dynamic> signal) async {
    final candidate = signal['candidate'];
    if (candidate is! Map<String, dynamic>) return;
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
    } else {
      await _addCandidate(candidate);
    }
  }

  Future<void> _flushPendingCandidates() async {
    final candidates = List<Map<String, dynamic>>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in candidates) {
      await _addCandidate(candidate);
    }
  }

  Future<void> _addCandidate(Map<String, dynamic> candidate) =>
      _peerConnection!.addCandidate(
        RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        ),
      );

  void _sendSignal(Map<String, dynamic> message) {
    if (!_socketOpen) {
      onLog('Signaling socket is not open.');
      return;
    }
    _socket!.sink.add(jsonEncode(message));
  }
}

Future<Uint8List> _aesEncrypt({
  required SecretKey key,
  required Uint8List plaintext,
  required Uint8List iv,
}) async {
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: key,
    nonce: iv,
  );
  return box.concatenation(nonce: false, mac: true);
}

Future<Uint8List> _aesDecrypt({
  required SecretKey key,
  required Uint8List ciphertext,
  required Uint8List iv,
}) async {
  final box = SecretBox.fromConcatenation(
    ciphertext,
    nonceLength: 0,
    macLength: 16,
  );
  return Uint8List.fromList(
    await AesGcm.with256bits().decrypt(
      SecretBox(box.cipherText, nonce: iv, mac: box.mac),
      secretKey: key,
    ),
  );
}

Future<void> _requestMediaPermissions({
  required bool audio,
  required bool video,
}) async {
  final permissions = <Permission>[
    if (audio) Permission.microphone,
    if (video) Permission.camera,
  ];
  if (permissions.isEmpty) return;
  final statuses = await permissions.request();
  final denied = statuses.entries
      .where((entry) => !entry.value.isGranted)
      .map((entry) => entry.key.toString())
      .toList(growable: false);
  if (denied.isNotEmpty) {
    throw StateError(
      'Required media permission was denied: ${denied.join(', ')}',
    );
  }
}

const MethodChannel _screenShareServiceChannel = MethodChannel(
  'peep/screen_share_service',
);

Future<void> _startScreenShareService() async {
  if (!Platform.isAndroid) return;
  await Permission.notification.request();
  await _screenShareServiceChannel.invokeMethod<void>('start');
}

Future<void> _stopScreenShareService() async {
  if (!Platform.isAndroid) return;
  await _screenShareServiceChannel.invokeMethod<void>('stop');
}

Uint8List _dataUrlBytes(String dataUrl) {
  final separator = dataUrl.indexOf(',');
  if (separator < 0) throw const FormatException('Invalid media data URL.');
  return Uint8List.fromList(base64Decode(dataUrl.substring(separator + 1)));
}

class _NativeAttachmentPlayer extends StatefulWidget {
  const _NativeAttachmentPlayer({required this.attachment});

  final AttachmentData attachment;

  @override
  State<_NativeAttachmentPlayer> createState() =>
      _NativeAttachmentPlayerState();
}

class _NativeAttachmentPlayerState extends State<_NativeAttachmentPlayer> {
  VideoPlayerController? _videoController;
  AudioPlayer? _audioPlayer;
  bool _audioPlaying = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final bytes = _dataUrlBytes(widget.attachment.dataUrl);
      if (widget.attachment.isVideo) {
        final directory = await getTemporaryDirectory();
        final safeName = widget.attachment.name.replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '_',
        );
        final file = File(
          '${directory.path}/peep-${DateTime.now().microsecondsSinceEpoch}-$safeName',
        );
        await file.writeAsBytes(bytes, flush: true);
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        _videoController = controller;
      } else {
        _audioPlayer = AudioPlayer();
      }
    } catch (error) {
      _error = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  Future<void> _toggleVideo() async {
    final controller = _videoController;
    if (controller == null) return;
    controller.value.isPlaying
        ? await controller.pause()
        : await controller.play();
    if (mounted) setState(() {});
  }

  Future<void> _toggleAudio() async {
    final player = _audioPlayer;
    if (player == null) return;
    if (_audioPlaying) {
      await player.pause();
    } else {
      await player.play(BytesSource(_dataUrlBytes(widget.attachment.dataUrl)));
    }
    if (mounted) setState(() => _audioPlaying = !_audioPlaying);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white70),
      );
    }
    if (widget.attachment.isVideo) {
      final controller = _videoController!;
      return GestureDetector(
        onTap: _toggleVideo,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            Center(
              child: Icon(
                controller.value.isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill,
                size: 54,
                color: Colors.white.withValues(alpha: 0.88),
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: IconButton.filledTonal(
        onPressed: _toggleAudio,
        icon: Icon(_audioPlaying ? Icons.pause : Icons.play_arrow),
      ),
    );
  }
}
