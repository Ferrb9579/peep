// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

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
    this.attachment,
  });

  final String text;
  final bool isLocal;
  final DateTime sentAt;
  final AttachmentData? attachment;
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

class PeerClient {
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
  final Map<String, _IncomingAttachment> _incomingAttachments = {};
  JSAny? _privateKey;
  JSAny? _aesKey;
  String? _roomKeyStorageKey;
  bool _remoteDescriptionSet = false;
  bool _offerStarted = false;
  bool _closed = false;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  CallState _callState = CallState.idle;
  static int _nextViewId = 0;
  static int _nextAttachmentId = 0;
  static const int _attachmentChunkSize = 16 * 1024;

  bool get canSend => _dataChannel?.readyState == 'open';
  bool get canStoreOffline =>
      _socket?.readyState == html.WebSocket.OPEN && encryptionReady;
  bool get canMessage => canSend || canStoreOffline;
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
  bool get encryptionReady => _aesKey != null;
  CallState get callState => _callState;
  bool get callActive => _callState != CallState.idle;
  String get localVideoViewType => _localVideoViewType;
  String get remoteVideoViewType => _remoteVideoViewType;

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
    return html.VideoElement()
      ..autoplay = true
      ..muted = muted
      ..controls = false
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.backgroundColor = '#111827';
  }

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
  }) async {
    await disconnect();
    _closed = false;
    _remoteDescriptionSet = false;
    _offerStarted = false;
    _cameraEnabled = false;
    _microphoneEnabled = false;
    _callState = CallState.idle;
    _pendingCandidates.clear();
    _pendingMessages.clear();
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _privateKey = null;
    _aesKey = null;
    _roomKeyStorageKey = 'peep:e2ee-room:${room.trim()}';
    await _loadPersistedRoomKey();

    onStatus(PeerStatus.signaling);
    _peerConnection = html.RtcPeerConnection({'iceServers': []});

    _wirePeerConnection();
    _peerConnection!.onDataChannel.listen((event) {
      final channel = event.channel;
      if (channel != null) {
        _attachDataChannel(channel);
      }
    });

    final url = signalingUri.replace(
      queryParameters: {
        ...signalingUri.queryParameters,
        'room': room,
        'peer': peerId,
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

    final input = html.FileUploadInputElement()
      ..accept = 'audio/*,video/*'
      ..multiple = false;
    final completer = Completer<html.File?>();
    input.onChange.first.then((_) {
      completer.complete(
        input.files?.isNotEmpty == true ? input.files!.first : null,
      );
    });
    input.click();

    final file = await completer.future;
    if (file == null) {
      return;
    }
    if (!file.type.startsWith('audio/') && !file.type.startsWith('video/')) {
      onLog('Choose an audio or video file.');
      return;
    }

    final dataUrl = await _readFileAsDataUrl(file);
    final attachment = _createAttachmentData(
      name: file.name,
      mimeType: file.type,
      size: file.size,
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

    await _sendAttachment(file: file, dataUrl: dataUrl);
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
      await _startLocalMedia(audio: true, video: false);
      _callState = CallState.active;
      _sendControl({'kind': 'call-accept'});
      onLog('Call accepted.');
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
    if (_callState != CallState.active) {
      onLog('Start a call before turning on video.');
      return;
    }

    if (enabled && _localStream?.getVideoTracks().isEmpty != false) {
      try {
        await _startLocalMedia(audio: true, video: true);
        await _createAndSendOffer();
      } catch (error) {
        _cameraEnabled = false;
        onLog('Could not start camera: $error');
        onMediaChanged();
      }
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
        await _startLocalMedia(audio: true, video: _cameraEnabled);
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

  Future<void> disconnect() async {
    _closed = true;
    _dataChannel?.close();
    _peerConnection?.close();
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
    _callState = CallState.idle;
    _localVideo.srcObject = null;
    _remoteVideo.srcObject = null;
    _pendingMessages.clear();
    _pendingEncryptedPayloads.clear();
    _incomingAttachments.clear();
    _privateKey = null;
    _aesKey = null;
    _roomKeyStorageKey = null;
    onStatus(PeerStatus.disconnected);
    onMediaChanged();
  }

  void _wirePeerConnection() {
    final peerConnection = _peerConnection!;

    peerConnection.onIceCandidate.listen((event) {
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
      switch (peerConnection.connectionState) {
        case 'connected':
          onStatus(PeerStatus.connected);
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
      onLog('ICE state: ${peerConnection.iceConnectionState ?? 'unknown'}');
    });

    peerConnection.onTrack.listen((event) {
      final stream = event.streams?.isNotEmpty == true
          ? event.streams!.first
          : _remoteStream ?? html.MediaStream();
      final track = event.track;
      if (event.streams?.isNotEmpty != true && track != null) {
        stream.addTrack(track);
      }

      _remoteStream = stream;
      _remoteVideo.srcObject = stream;
      onLog('Remote ${track?.kind ?? 'media'} track received.');
      onMediaChanged();
    });
  }

  Future<void> _startLocalMedia({
    required bool audio,
    required bool video,
  }) async {
    onLog(
      'Requesting ${video ? 'camera' : ''}${video && audio ? ' and ' : ''}${audio ? 'microphone' : ''}.',
    );
    final stream = await html.window.navigator.mediaDevices!.getUserMedia({
      'audio': audio,
      'video': video
          ? {
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    });

    _localStream ??= html.MediaStream();
    for (final track in stream.getTracks()) {
      _localStream!.addTrack(track);
      _peerConnection!.addTrack(track, stream);
    }
    _localVideo.srcObject = _localStream;
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

  void _attachDataChannel(html.RtcDataChannel channel) {
    _dataChannel = channel;

    channel.onOpen.listen((_) {
      unawaited(_handleDataChannelOpen());
    });

    channel.onClose.listen((_) {
      if (!_closed) {
        _dataChannel = null;
        onStatus(PeerStatus.waitingForPeer);
        onMediaChanged();
      }
      onLog('Data channel closed.');
    });

    channel.onMessage.listen((event) {
      final data = event.data;
      if (data is String) {
        _handleDataChannelMessage(data);
      }
    });
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
    _localStream?.getTracks().forEach((track) => track.stop());
    _remoteStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;
    _remoteStream = null;
    _localVideo.srcObject = null;
    _remoteVideo.srcObject = null;
    _cameraEnabled = false;
    _microphoneEnabled = false;
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

  Future<void> _sendAttachment({
    required html.File file,
    required String dataUrl,
  }) async {
    final id =
        'attachment-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}';
    await _sendControl({
      'kind': 'attachment-start',
      'id': id,
      'name': file.name,
      'mimeType': file.type,
      'size': file.size,
    });

    for (
      var offset = 0;
      offset < dataUrl.length;
      offset += _attachmentChunkSize
    ) {
      final chunkEnd = offset + _attachmentChunkSize;
      final end = chunkEnd > dataUrl.length ? dataUrl.length : chunkEnd;
      await _sendControl({
        'kind': 'attachment-chunk',
        'id': id,
        'data': dataUrl.substring(offset, end),
      });
      await _waitForBufferedAmount();
    }

    await _sendControl({'kind': 'attachment-end', 'id': id});
    onLog('Attachment sent: ${file.name}.');
  }

  Future<String> _readFileAsDataUrl(html.File file) {
    final completer = Completer<String>();
    final reader = html.FileReader();

    reader.onLoad.first.then((_) {
      final result = reader.result;
      if (result is String) {
        completer.complete(result);
      } else {
        completer.completeError(StateError('Could not read attachment.'));
      }
    });
    reader.onError.first.then((_) {
      completer.completeError(StateError('Could not read attachment.'));
    });
    reader.readAsDataUrl(file);

    return completer.future;
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

    _incomingAttachments[id] = _IncomingAttachment(
      name: name,
      mimeType: mimeType,
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

    _incomingAttachments[id]?.data.write(data);
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

    final attachment = _createAttachmentData(
      name: incoming.name,
      mimeType: incoming.mimeType,
      size: incoming.size,
      dataUrl: incoming.data.toString(),
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
          ..style.width = '100%';
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
    _sendPlainDataChannel({
      'kind': 'e2ee-key',
      'publicKey': base64Encode(publicBytes.toDart.asUint8List()),
    });
    onLog('E2EE key sent.');
  }

  Future<void> _handleEncryptionKey(Map<String, dynamic> message) async {
    final publicKey = message['publicKey'];
    if (publicKey is! String || _privateKey == null) {
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
    final completer = Completer<void>();
    final socket = html.WebSocket(uri.toString());
    _socket = socket;

    socket.onOpen.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      onLog('Signaling connected.');
    });

    socket.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Could not connect to signaling server.'),
        );
      }
      onStatus(PeerStatus.failed);
      onLog('Signaling socket error.');
    });

    socket.onClose.listen((_) {
      if (!_closed) {
        onStatus(PeerStatus.disconnected);
      }
      onLog('Signaling disconnected.');
    });

    socket.onMessage.listen((event) {
      final data = event.data;
      if (data is String) {
        unawaited(_handleSignal(data));
      }
    });

    return completer.future.timeout(const Duration(seconds: 8));
  }

  Future<void> _createAndSendOffer({bool ensureDataChannel = false}) async {
    if (ensureDataChannel && _offerStarted) {
      return;
    }

    if (ensureDataChannel) {
      _offerStarted = true;
    }
    onStatus(PeerStatus.connecting);
    if (ensureDataChannel && _dataChannel == null) {
      _attachDataChannel(_peerConnection!.createDataChannel('chat'));
    }
    final offer = await _createDescription('createOffer');
    await _setLocalDescription(offer);
    _sendSignal({'type': 'offer', 'description': offer});
  }

  Future<void> _handleSignal(String raw) async {
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
            _dataChannel = null;
            onStatus(PeerStatus.waitingForPeer);
            onMediaChanged();
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
      onStatus(PeerStatus.failed);
      onLog('Signal handling failed: $error');
    }
  }

  Future<void> _handleWelcome(Map<String, dynamic> signal) async {
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
    final description = signal['description'];
    if (description is! Map<String, dynamic>) {
      return;
    }

    onStatus(PeerStatus.connecting);
    await _setRemoteDescription({
      'type': description['type'],
      'sdp': description['sdp'],
    });
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    final answer = await _createDescription('createAnswer');
    await _setLocalDescription(answer);
    _sendSignal({'type': 'answer', 'description': answer});
  }

  Future<void> _handleAnswer(Map<String, dynamic> signal) async {
    final description = signal['description'];
    if (description is! Map<String, dynamic>) {
      return;
    }

    await _setRemoteDescription({
      'type': description['type'],
      'sdp': description['sdp'],
    });
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
  }

  Future<void> _handleCandidate(Map<String, dynamic> signal) async {
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

  Future<Map<String, dynamic>> _createDescription(String method) async {
    final peerConnection = JSObject.fromInteropObject(_peerConnection!);
    final description = await peerConnection
        .callMethod<JSPromise<JSObject>>(method.toJS)
        .toDart;

    return {
      'type': (description['type'] as JSString?)?.toDart,
      'sdp': (description['sdp'] as JSString?)?.toDart,
    };
  }

  Future<void> _setLocalDescription(Map<String, dynamic> description) {
    final peerConnection = JSObject.fromInteropObject(_peerConnection!);
    return peerConnection
        .callMethod<JSPromise<JSAny?>>(
          'setLocalDescription'.toJS,
          description.jsify(),
        )
        .toDart;
  }

  Future<void> _setRemoteDescription(Map<String, dynamic> description) {
    final peerConnection = JSObject.fromInteropObject(_peerConnection!);
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
