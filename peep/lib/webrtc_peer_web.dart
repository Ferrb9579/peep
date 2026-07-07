// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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

  html.RtcPeerConnection? _peerConnection;
  html.RtcDataChannel? _dataChannel;
  html.WebSocket? _socket;
  final List<Map<String, dynamic>> _pendingCandidates = [];
  final List<String> _pendingMessages = [];
  bool _remoteDescriptionSet = false;
  bool _offerStarted = false;
  bool _closed = false;

  bool get canSend => _dataChannel?.readyState == 'open';

  Future<void> connect({
    required Uri signalingUri,
    required String room,
    required String peerId,
  }) async {
    await disconnect();
    _closed = false;
    _remoteDescriptionSet = false;
    _offerStarted = false;
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

  Future<void> disconnect() async {
    _closed = true;
    _dataChannel?.close();
    _peerConnection?.close();
    _socket?.close();
    _dataChannel = null;
    _peerConnection = null;
    _socket = null;
    _pendingMessages.clear();
    onStatus(PeerStatus.disconnected);
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
        onMessage(
          ChatMessage(text: data, isLocal: false, sentAt: DateTime.now()),
        );
      }
    });
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
    _dataChannel!.sendString(text);
    onMessage(ChatMessage(text: text, isLocal: true, sentAt: DateTime.now()));
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

  Future<void> _createAndSendOffer() async {
    if (_offerStarted) {
      return;
    }

    _offerStarted = true;
    onStatus(PeerStatus.connecting);
    _attachDataChannel(_peerConnection!.createDataChannel('chat'));
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
      await _createAndSendOffer();
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
