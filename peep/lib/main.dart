import 'dart:async';

import 'package:flutter/material.dart';

import 'webrtc_peer_stub.dart' if (dart.library.html) 'webrtc_peer_web.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f7a8c),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const PeerChatScreen(),
    );
  }
}

class PeerChatScreen extends StatefulWidget {
  const PeerChatScreen({super.key});

  @override
  State<PeerChatScreen> createState() => _PeerChatScreenState();
}

class _PeerChatScreenState extends State<PeerChatScreen> {
  final _signalingController = TextEditingController(
    text: 'ws://127.0.0.1:8787/ws',
  );
  final _roomController = TextEditingController(text: 'demo');
  final _peerController = TextEditingController(
    text: 'peer-${DateTime.now().millisecondsSinceEpoch % 100000}',
  );
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  late final PeerClient _client;
  PeerStatus _status = PeerStatus.idle;
  final List<ChatMessage> _messages = [];
  final List<String> _logs = [];

  bool get _isConnected =>
      _status == PeerStatus.signaling ||
      _status == PeerStatus.waitingForPeer ||
      _status == PeerStatus.connecting ||
      _status == PeerStatus.connected;

  @override
  void initState() {
    super.initState();
    _client = PeerClient(
      onStatus: (status) {
        if (mounted) {
          setState(() => _status = status);
        }
      },
      onMessage: (message) {
        if (mounted) {
          setState(() => _messages.add(message));
          _scrollToEnd();
        }
      },
      onLog: (message) {
        if (mounted) {
          setState(() {
            _logs
              ..add(message)
              ..removeRange(0, _logs.length > 80 ? _logs.length - 80 : 0);
          });
        }
      },
      onMediaChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    _client.disconnect();
    _signalingController.dispose();
    _roomController.dispose();
    _peerController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();

    try {
      await _client.connect(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        room: _roomController.text.trim(),
        peerId: _peerController.text.trim(),
      );
    } catch (error) {
      setState(() => _status = PeerStatus.failed);
      _addLog('Connect failed: $error');
    }
  }

  Future<void> _disconnect() async {
    await _client.disconnect();
  }

  void _toggleCamera() {
    unawaited(_client.setCameraEnabled(!_client.cameraEnabled));
  }

  void _toggleMicrophone() {
    unawaited(_client.setMicrophoneEnabled(!_client.microphoneEnabled));
  }

  void _startCall() {
    _client.startCall();
  }

  void _acceptCall() {
    unawaited(_client.acceptCall());
  }

  void _declineCall() {
    _client.declineCall();
  }

  void _endCall() {
    unawaited(_client.endCall());
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    _client.send(text);
    _messageController.clear();
    _scrollToEnd();
  }

  void _sendAttachment() {
    unawaited(_client.pickAndSendAttachment());
  }

  void _addLog(String message) {
    setState(() {
      _logs
        ..add(message)
        ..removeRange(0, _logs.length > 80 ? _logs.length - 80 : 0);
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff7f3ea),
      appBar: AppBar(
        title: const Text('Peep'),
        backgroundColor: const Color(0xfff7f3ea),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final colorScheme = Theme.of(context).colorScheme;
            final wide = constraints.maxWidth >= 900;
            if (!_isConnected) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _SetupPanel(
                      signalingController: _signalingController,
                      roomController: _roomController,
                      peerController: _peerController,
                      enabled: true,
                      connected: false,
                      onConnect: _connect,
                      onDisconnect: _disconnect,
                      logs: _logs,
                    ),
                  ),
                ),
              );
            }

            final chatHeader = _ChatHeader(
              room: _roomController.text.trim(),
              peer: _peerController.text.trim(),
              statusLabel: _statusLabel(),
              statusColor: _statusColor(colorScheme),
              cameraEnabled: _client.cameraEnabled,
              microphoneEnabled: _client.microphoneEnabled,
              encryptionReady: _client.encryptionReady,
              callState: _client.callState,
              onBack: _disconnect,
              onStartCall: _startCall,
              onEndCall: _endCall,
              onToggleCamera: _toggleCamera,
              onToggleMicrophone: _toggleMicrophone,
            );
            final callNotice = _CallNotice(
              callState: _client.callState,
              onAccept: _acceptCall,
              onDecline: _declineCall,
              onEnd: _endCall,
            );
            final call = _CallPanel(
              localVideoViewType: _client.localVideoViewType,
              remoteVideoViewType: _client.remoteVideoViewType,
              connected: _isConnected,
            );
            final chat = _ChatPanel(
              messages: _messages,
              scrollController: _scrollController,
              messageController: _messageController,
              canType: _isConnected,
              canSend: _client.canMessage,
              onSend: _sendMessage,
              onAttach: _sendAttachment,
            );

            return Padding(
              padding: EdgeInsets.fromLTRB(
                wide ? 24 : 16,
                8,
                wide ? 24 : 16,
                wide ? 24 : 16,
              ),
              child: Column(
                children: [
                  chatHeader,
                  if (_client.callState == CallState.incoming ||
                      _client.callState == CallState.outgoing) ...[
                    const SizedBox(height: 12),
                    callNotice,
                  ],
                  if (_client.callState == CallState.active) ...[
                    const SizedBox(height: 12),
                    SizedBox(height: wide ? 280 : 260, child: call),
                  ],
                  const SizedBox(height: 12),
                  Expanded(child: chat),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _statusLabel() {
    if (_client.canSend) {
      return 'Connected';
    }

    return switch (_status) {
      PeerStatus.idle => 'Idle',
      PeerStatus.signaling => 'Signaling',
      PeerStatus.waitingForPeer => 'Waiting',
      PeerStatus.connecting => 'Connecting',
      PeerStatus.connected => 'Connected',
      PeerStatus.disconnected => 'Disconnected',
      PeerStatus.failed => 'Failed',
    };
  }

  Color _statusColor(ColorScheme colorScheme) {
    if (_client.canSend) {
      return const Color(0xff287d4f);
    }

    return switch (_status) {
      PeerStatus.connected => const Color(0xff287d4f),
      PeerStatus.connecting ||
      PeerStatus.signaling ||
      PeerStatus.waitingForPeer => const Color(0xffb26a00),
      PeerStatus.failed => colorScheme.error,
      _ => const Color(0xff6b7280),
    };
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.room,
    required this.peer,
    required this.statusLabel,
    required this.statusColor,
    required this.cameraEnabled,
    required this.microphoneEnabled,
    required this.encryptionReady,
    required this.callState,
    required this.onBack,
    required this.onStartCall,
    required this.onEndCall,
    required this.onToggleCamera,
    required this.onToggleMicrophone,
  });

  final String room;
  final String peer;
  final String statusLabel;
  final Color statusColor;
  final bool cameraEnabled;
  final bool microphoneEnabled;
  final bool encryptionReady;
  final CallState callState;
  final VoidCallback onBack;
  final VoidCallback onStartCall;
  final VoidCallback onEndCall;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleMicrophone;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffded6c9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Disconnect',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room.isEmpty ? 'Direct chat' : room,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    peer,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Chip(
              label: Text(statusLabel),
              backgroundColor: statusColor.withValues(alpha: 0.15),
              side: BorderSide(color: statusColor),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: encryptionReady
                  ? 'End-to-end encryption ready'
                  : 'Setting up end-to-end encryption',
              child: Icon(
                encryptionReady ? Icons.lock : Icons.lock_clock,
                color: encryptionReady
                    ? const Color(0xff287d4f)
                    : const Color(0xffb26a00),
              ),
            ),
            const SizedBox(width: 8),
            if (callState == CallState.idle)
              IconButton.filled(
                onPressed: onStartCall,
                icon: const Icon(Icons.call),
                tooltip: 'Start call',
              )
            else
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffb42318),
                  foregroundColor: Colors.white,
                ),
                onPressed: onEndCall,
                icon: const Icon(Icons.call_end),
                tooltip: 'End call',
              ),
            const SizedBox(width: 8),
            if (callState == CallState.active) ...[
              IconButton.filledTonal(
                onPressed: onToggleMicrophone,
                icon: Icon(microphoneEnabled ? Icons.mic : Icons.mic_off),
                tooltip: microphoneEnabled ? 'Mute microphone' : 'Unmute audio',
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onToggleCamera,
                icon: Icon(cameraEnabled ? Icons.videocam : Icons.videocam_off),
                tooltip: cameraEnabled ? 'Turn camera off' : 'Start video',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CallNotice extends StatelessWidget {
  const _CallNotice({
    required this.callState,
    required this.onAccept,
    required this.onDecline,
    required this.onEnd,
  });

  final CallState callState;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final incoming = callState == CallState.incoming;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffded6c9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              incoming ? Icons.call_received : Icons.call_made,
              color: const Color(0xff1f7a8c),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                incoming ? 'Incoming audio call' : 'Calling...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (incoming) ...[
              FilledButton.icon(
                onPressed: onAccept,
                icon: const Icon(Icons.call),
                label: const Text('Accept'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onDecline,
                icon: const Icon(Icons.call_end),
                label: const Text('Decline'),
              ),
            ] else
              OutlinedButton.icon(
                onPressed: onEnd,
                icon: const Icon(Icons.call_end),
                label: const Text('Cancel'),
              ),
          ],
        ),
      ),
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel({
    required this.localVideoViewType,
    required this.remoteVideoViewType,
    required this.connected,
  });

  final String? localVideoViewType;
  final String? remoteVideoViewType;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffded6c9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: _VideoTile(
                title: 'Remote',
                viewType: remoteVideoViewType,
                placeholder: connected
                    ? 'Waiting for remote video'
                    : 'Connect to start a call',
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 240,
              child: _VideoTile(
                title: 'You',
                viewType: localVideoViewType,
                placeholder: connected ? 'Starting camera' : 'Local preview',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.title,
    required this.viewType,
    required this.placeholder,
  });

  final String title;
  final String? viewType;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xff111827),
            child: viewType == null
                ? Center(
                    child: Text(
                      placeholder,
                      style: const TextStyle(color: Color(0xffcbd5e1)),
                    ),
                  )
                : HtmlElementView(viewType: viewType!),
          ),
          Positioned(
            left: 10,
            top: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupPanel extends StatelessWidget {
  const _SetupPanel({
    required this.signalingController,
    required this.roomController,
    required this.peerController,
    required this.enabled,
    required this.connected,
    required this.onConnect,
    required this.onDisconnect,
    required this.logs,
  });

  final TextEditingController signalingController;
  final TextEditingController roomController;
  final TextEditingController peerController;
  final bool enabled;
  final bool connected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffded6c9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: signalingController,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: 'Signaling URL',
                prefixIcon: Icon(Icons.dns_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: roomController,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: 'Room',
                prefixIcon: Icon(Icons.meeting_room_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: peerController,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: 'Peer name',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xffeef6f7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xffb8d7dc)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.auto_mode, size: 20, color: Color(0xff1f7a8c)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Role is automatic. First tab waits; second tab starts the connection.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: connected ? onDisconnect : onConnect,
              icon: Icon(connected ? Icons.link_off : Icons.link),
              label: Text(connected ? 'Disconnect' : 'Connect'),
            ),
            const SizedBox(height: 16),
            Text('Events', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Container(
              height: 180,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xff1f2933),
                borderRadius: BorderRadius.circular(8),
              ),
              child: logs.isEmpty
                  ? const Text(
                      'No events yet.',
                      style: TextStyle(color: Color(0xffcbd5e1)),
                    )
                  : ListView.builder(
                      itemCount: logs.length,
                      itemBuilder: (context, index) => Text(
                        logs[index],
                        style: const TextStyle(
                          color: Color(0xffe5e7eb),
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatPanel extends StatelessWidget {
  const _ChatPanel({
    required this.messages,
    required this.scrollController,
    required this.messageController,
    required this.canType,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final TextEditingController messageController;
  final bool canType;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffded6c9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.forum_outlined),
                const SizedBox(width: 8),
                Text('Messages', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'Messages sent here use the WebRTC data channel.',
                    ),
                  )
                : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final attachment = message.attachment;
                      return Align(
                        alignment: message.isLocal
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: message.isLocal
                                  ? const Color(0xff1f7a8c)
                                  : const Color(0xffedf2f4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: attachment == null
                                ? Text(
                                    message.text,
                                    style: TextStyle(
                                      color: message.isLocal
                                          ? Colors.white
                                          : const Color(0xff111827),
                                    ),
                                  )
                                : _AttachmentBubble(
                                    attachment: attachment,
                                    isLocal: message.isLocal,
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton.filledTonal(
                  onPressed: canSend ? onAttach : null,
                  icon: const Icon(Icons.attach_file),
                  tooltip: 'Attach audio or video',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: messageController,
                    enabled: canType,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: canType ? (_) => onSend() : null,
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: canType ? onSend : null,
                  icon: const Icon(Icons.send),
                  tooltip: canSend ? 'Send' : 'Queue until connected',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentBubble extends StatelessWidget {
  const _AttachmentBubble({required this.attachment, required this.isLocal});

  final AttachmentData attachment;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final textColor = isLocal ? Colors.white : const Color(0xff111827);
    final mediaHeight = attachment.isVideo ? 220.0 : 48.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              attachment.isVideo
                  ? Icons.movie_outlined
                  : Icons.audio_file_outlined,
              size: 20,
              color: textColor,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${attachment.mimeType} • ${_formatBytes(attachment.size)}',
          style: TextStyle(color: textColor.withValues(alpha: 0.82)),
        ),
        if (attachment.viewType != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 460,
              height: mediaHeight,
              child: HtmlElementView(viewType: attachment.viewType!),
            ),
          ),
        ],
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }
}
