// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
  bool _remoteDescriptionSet = false;
  bool _offerStarted = false;
  bool _closed = false;
  bool _cameraEnabled = false;
  bool _microphoneEnabled = false;
  CallState _callState = CallState.idle;
  static int _nextViewId = 0;

  bool get canSend => _dataChannel?.readyState == 'open';
  bool get cameraEnabled => _cameraEnabled;
  bool get microphoneEnabled => _microphoneEnabled;
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
    if (!canSend) {
      _pendingMessages.add(text);
      onLog('Queued message until the data channel opens.');
      return;
    }

    _sendDataChannelMessage(text);
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
      onStatus(PeerStatus.connected);
      onLog('Data channel opened.');
      _flushPendingMessages();
    });

    channel.onClose.listen((_) {
      if (!_closed) {
        onStatus(PeerStatus.disconnected);
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

  void _handleDataChannelMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        switch (decoded['kind']) {
          case 'chat':
            final text = decoded['text'];
            if (text is String) {
              onMessage(
                ChatMessage(text: text, isLocal: false, sentAt: DateTime.now()),
              );
            }
            return;
          case 'call-request':
            if (_callState == CallState.idle) {
              _callState = CallState.incoming;
              onLog('Incoming call request.');
              onMediaChanged();
            } else {
              _sendControl({'kind': 'call-decline'});
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
    } catch (_) {
      onMessage(ChatMessage(text: raw, isLocal: false, sentAt: DateTime.now()));
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
    _dataChannel!.sendString(jsonEncode({'kind': 'chat', 'text': text}));
    onMessage(ChatMessage(text: text, isLocal: true, sentAt: DateTime.now()));
  }

  void _sendControl(Map<String, dynamic> message) {
    if (!canSend) {
      onLog('Data channel is not open.');
      return;
    }

    _dataChannel!.sendString(jsonEncode(message));
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
          onLog('Peer ${decoded['peer']} ${decoded['event']}.');
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
