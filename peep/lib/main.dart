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

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    _client.send(text);
    _messageController.clear();
    _scrollToEnd();
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xfff7f3ea),
      appBar: AppBar(
        title: const Text('Peep'),
        backgroundColor: const Color(0xfff7f3ea),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              avatar: Icon(_statusIcon(), size: 18),
              label: Text(_statusLabel()),
              backgroundColor: _statusColor(
                colorScheme,
              ).withValues(alpha: 0.15),
              side: BorderSide(color: _statusColor(colorScheme)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final setup = _SetupPanel(
              signalingController: _signalingController,
              roomController: _roomController,
              peerController: _peerController,
              enabled: !_isConnected,
              connected: _isConnected,
              onConnect: _connect,
              onDisconnect: _disconnect,
              logs: _logs,
            );
            final chat = _ChatPanel(
              messages: _messages,
              scrollController: _scrollController,
              messageController: _messageController,
              canType: _isConnected,
              canSend: _client.canSend,
              onSend: _sendMessage,
            );

            if (wide) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 360, child: setup),
                    const SizedBox(width: 24),
                    Expanded(child: chat),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  setup,
                  const SizedBox(height: 16),
                  Expanded(child: chat),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  IconData _statusIcon() {
    return switch (_status) {
      PeerStatus.connected => Icons.hub,
      PeerStatus.connecting || PeerStatus.signaling => Icons.sync,
      PeerStatus.failed => Icons.error_outline,
      PeerStatus.disconnected => Icons.link_off,
      _ => Icons.radio_button_unchecked,
    };
  }

  String _statusLabel() {
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
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final TextEditingController messageController;
  final bool canType;
  final bool canSend;
  final VoidCallback onSend;

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
                            child: Text(
                              message.text,
                              style: TextStyle(
                                color: message.isLocal
                                    ? Colors.white
                                    : const Color(0xff111827),
                              ),
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
                Expanded(
                  child: TextField(
                    controller: messageController,
                    enabled: canType,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: canType ? (_) => onSend() : null,
                    decoration: const InputDecoration(
                      hintText:
                          'Type a message while the peer connection opens',
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
