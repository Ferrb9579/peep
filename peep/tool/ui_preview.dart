// Development gallery: sample conversations never enter the production app.
import 'package:flutter/material.dart';
import 'package:peep/peer.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/ui/account_screen.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/conversation_screen.dart';
import 'package:peep/ui/media_settings_sheet.dart';
import 'package:peep/ui/messenger_home.dart';
import 'package:peep/ui/peep_theme.dart';

void main() => runApp(
  MaterialApp(
    title: 'Peep · UI preview',
    theme: buildPeepTheme(),
    debugShowCheckedModeBanner: false,
    home: const _Gallery(),
  ),
);

class _Gallery extends StatefulWidget {
  const _Gallery();
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final _controllers = List.generate(7, (_) => TextEditingController());
  final _scroll = ScrollController();
  late String _screen;
  MediaSettings _settings = MediaSettings.defaults;
  @override
  void initState() {
    super.initState();
    _screen = Uri.base.queryParameters['screen'] ?? 'home';
    _controllers[0].text = 'ws://127.0.0.1:8787/ws';
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _media() => showMediaSettings(
    context,
    settings: _settings,
    loadCodecs: discoverMediaCodecs,
    inCall: _screen == 'call',
    onSave: (settings) async {
      setState(() => _settings = settings);
      return null;
    },
  );
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final screen = switch (_screen) {
      'account' => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: AccountScreen(
              signalingController: _controllers[0],
              emailController: _controllers[1],
              usernameController: _controllers[2],
              passwordController: _controllers[3],
              busy: false,
              onCreateAccount: () {},
              onSignIn: () {},
            ),
          ),
        ),
      ),
      'chat' => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            children: [
              ConversationHeader(
                room: 'Maya',
                peer: 'Direct conversation',
                statusLabel: 'Connected',
                statusColor: PeepColors.primary,
                encryptionReady: true,
                canReconnect: false,
                onBack: () => setState(() => _screen = 'home'),
                onReconnect: () {},
                onStartCall: () => setState(() => _screen = 'call'),
                onMediaSettings: _media,
              ),
              Expanded(
                child: ConversationPanel(
                  messages: [
                    ChatMessage(
                      text:
                          'Hey! Did you get a chance to look at the weekend plans?',
                      isLocal: false,
                      sentAt: now.subtract(const Duration(minutes: 12)),
                    ),
                    ChatMessage(
                      text:
                          'I did! That little place by the water looks perfect.',
                      isLocal: true,
                      sentAt: now.subtract(const Duration(minutes: 10)),
                    ),
                    ChatMessage(
                      text: 'A long walk, good coffee, absolutely no agenda.',
                      isLocal: false,
                      sentAt: now.subtract(const Duration(minutes: 8)),
                    ),
                    ChatMessage(
                      text: 'Count me in. Saturday at 10?',
                      isLocal: true,
                      sentAt: now.subtract(const Duration(minutes: 5)),
                    ),
                    ChatMessage(
                      text: 'It’s a plan. I’ll bring the camera.',
                      isLocal: false,
                      sentAt: now.subtract(const Duration(minutes: 4)),
                    ),
                  ],
                  scrollController: _scroll,
                  messageController: _controllers[6],
                  canType: true,
                  canSend: true,
                  canAttach: true,
                  onSend: () => _controllers[6].clear(),
                  onAttach: () {},
                ),
              ),
            ],
          ),
        ),
      ),
      'call' => CallScreen(
        title: 'The weekend crew',
        subtitle: 'Group call',
        callState: CallState.active,
        connected: true,
        cameraEnabled: false,
        microphoneEnabled: true,
        screenShareEnabled: false,
        localVideoViewType: null,
        remoteVideoViews: const [
          MediaView(title: 'Maya', viewType: null),
          MediaView(title: 'Alex', viewType: null),
          MediaView(title: 'Sam', viewType: null),
        ],
        onAccept: () {},
        onDecline: () {},
        onEnd: () => setState(() => _screen = 'chat'),
        onToggleCamera: () {},
        onToggleMicrophone: () {},
        onToggleScreenShare: () {},
        onMediaSettings: _media,
      ),
      _ => MessengerHome(
        signalingController: _controllers[0],
        contactController: _controllers[1],
        groupNameController: _controllers[4],
        groupMembersController: _controllers[5],
        session: const AuthSession(
          token: 'preview',
          username: 'jordan',
          email: 'jordan@example.test',
        ),
        chatEntries: [
          ChatListEntry(
            contactUsername: 'Maya',
            lastText: 'It’s a plan. I’ll bring the camera.',
            updatedAt: now,
            unreadCount: 2,
          ),
          ChatListEntry(
            contactUsername: 'Alex',
            lastText: 'That playlist is exactly what I needed.',
            updatedAt: now.subtract(const Duration(hours: 2)),
            unreadCount: 1,
          ),
          ChatListEntry(
            contactUsername: 'Sam',
            lastText: 'You: Coffee next week?',
            updatedAt: now.subtract(const Duration(days: 1)),
            unreadCount: 0,
          ),
          ChatListEntry(
            contactUsername: 'Ellie',
            lastText: 'Sent you the recording. Let me know what you think.',
            updatedAt: now.subtract(const Duration(days: 2)),
            unreadCount: 0,
          ),
        ],
        groups: const [
          GroupSummary(
            id: 'weekend',
            name: 'The weekend crew',
            members: ['Maya', 'Alex', 'Sam', 'jordan'],
          ),
          GroupSummary(
            id: 'studio',
            name: 'Studio notes',
            members: ['Ellie', 'jordan'],
          ),
        ],
        callHistory: [
          CallHistoryEntry(
            title: 'Maya',
            subtitle: 'Outgoing call',
            startedAt: now,
            outgoing: true,
          ),
        ],
        connecting: false,
        groupsBusy: false,
        onConnect: () => setState(() => _screen = 'chat'),
        onOpenChatEntry: (_) => setState(() => _screen = 'chat'),
        onCreateGroup: () async => null,
        onOpenGroup: (_) => setState(() => _screen = 'chat'),
        onRefreshGroups: () async {},
        onSignOut: () => setState(() => _screen = 'account'),
        logs: const ['Preview connection ready'],
        onMediaSettings: _media,
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 38,
              color: PeepColors.primarySoft,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Text(
                      'UI PREVIEW',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final screen in ['home', 'account', 'chat', 'call'])
                    TextButton(
                      onPressed: () => setState(() => _screen = screen),
                      child: Text(screen),
                    ),
                  TextButton(onPressed: _media, child: const Text('media')),
                ],
              ),
            ),
            Expanded(child: screen),
          ],
        ),
      ),
    );
  }
}
