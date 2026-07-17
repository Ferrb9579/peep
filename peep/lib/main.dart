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
    const primary = Color(0xff4f46e5);
    const ink = Color(0xff172033);
    const muted = Color(0xff667085);
    const border = Color(0xffe4e7ec);

    return MaterialApp(
      title: 'Peep',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.light,
          primary: primary,
          surface: Colors.white,
          error: const Color(0xffd92d20),
        ),
        scaffoldBackgroundColor: const Color(0xfff5f7fb),
        useMaterial3: true,
        dividerColor: border,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: ink,
            fontSize: 40,
            height: 1.12,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
          headlineSmall: TextStyle(
            color: ink,
            fontSize: 28,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          titleLarge: TextStyle(
            color: ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
          titleMedium: TextStyle(
            color: ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
          titleSmall: TextStyle(
            color: ink,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          bodyLarge: TextStyle(color: ink, fontSize: 16, height: 1.5),
          bodyMedium: TextStyle(color: ink, fontSize: 14, height: 1.45),
          bodySmall: TextStyle(color: muted, fontSize: 12, height: 1.4),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xfff9fafb),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: primary, width: 1.6),
          ),
          labelStyle: const TextStyle(color: muted),
          hintStyle: const TextStyle(color: Color(0xff98a2b3)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 50),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 50),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            side: const BorderSide(color: border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      home: const PeerChatScreen(),
    );
  }
}

abstract final class _Ui {
  static const primary = Color(0xff4f46e5);
  static const primarySoft = Color(0xffeef2ff);
  static const ink = Color(0xff172033);
  static const muted = Color(0xff667085);
  static const subtle = Color(0xff98a2b3);
  static const border = Color(0xffe4e7ec);
  static const success = Color(0xff0e9f6e);
  static const warning = Color(0xffd97706);
  static const danger = Color(0xffd92d20);
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
  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _contactController = TextEditingController();
  final _groupNameController = TextEditingController();
  final _groupMembersController = TextEditingController();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  late final PeerClient _client;
  late final GroupClient _groupClient;
  PeerStatus _status = PeerStatus.idle;
  AuthSession? _session;
  bool _authBusy = false;
  bool _groupsBusy = false;
  bool _groupChatActive = false;
  String _activeTitle = 'Direct chat';
  String _activeSubtitle = '';
  String? _activeConversationKey;
  GroupSummary? _activeGroup;
  final List<ChatMessage> _messages = [];
  final List<GroupSummary> _groups = [];
  final List<StoredConversation> _recentConversations = [];
  final List<MailboxSummary> _mailboxSummaries = [];
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
          _saveActiveHistory();
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
    _groupClient = GroupClient(
      onStatus: (status) {
        if (mounted) {
          setState(() => _status = status);
        }
      },
      onMessage: (message) {
        if (mounted) {
          setState(() => _messages.add(message));
          _saveActiveHistory();
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
    _groupClient.disconnect();
    _signalingController.dispose();
    _roomController.dispose();
    _peerController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _contactController.dispose();
    _groupNameController.dispose();
    _groupMembersController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    await _authenticate(
      () => createAccount(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        email: _emailController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      ),
      'Account created.',
    );
  }

  Future<void> _signIn() async {
    await _authenticate(
      () => signInAccount(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      ),
      'Signed in.',
    );
  }

  Future<void> _authenticate(
    Future<AuthSession> Function() action,
    String successMessage,
  ) async {
    FocusScope.of(context).unfocus();
    setState(() => _authBusy = true);

    try {
      final session = await action();
      setState(() {
        _session = session;
        _peerController.text = session.username;
        _refreshRecentConversations(session.username);
      });
      _addLog(successMessage);
      unawaited(_prepareSignedInSession(session));
    } catch (error) {
      _addLog('Account error: $error');
    } finally {
      if (mounted) {
        setState(() => _authBusy = false);
      }
    }
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final session = _session;
    final contact = _contactController.text.trim().toLowerCase();
    if (session == null) {
      _addLog('Sign in before starting a chat.');
      return;
    }
    if (contact.isEmpty) {
      _addLog('Enter a username to contact.');
      return;
    }
    if (contact == session.username) {
      _addLog('Choose another username to contact.');
      return;
    }

    try {
      await _groupClient.disconnect();
      final conversationKey = _directRoom(session.username, contact);
      final history = loadMessageHistory(conversationKey);
      _roomController.text = conversationKey;
      _peerController.text = session.username;
      setState(() {
        _groupChatActive = false;
        _activeTitle = contact;
        _activeSubtitle = session.username;
        _activeConversationKey = conversationKey;
        _activeGroup = null;
        _messages
          ..clear()
          ..addAll(history);
      });
      await _client.connect(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        room: _roomController.text,
        peerId: session.username,
        authToken: session.token,
        accountUsername: session.username,
        contactUsername: contact,
      );
      if (mounted) {
        setState(() {
          _mailboxSummaries.removeWhere(
            (summary) => summary.contactUsername == contact,
          );
        });
      }
    } catch (error) {
      setState(() => _status = PeerStatus.failed);
      _addLog('Connect failed: $error');
    }
  }

  Future<void> _disconnect() async {
    if (_groupChatActive) {
      await _groupClient.disconnect();
    } else {
      await _client.disconnect();
    }
    setState(() {
      _groupChatActive = false;
      _activeConversationKey = null;
      _activeGroup = null;
      _messages.clear();
    });
    final session = _session;
    if (session != null) {
      await _loadMailboxSummaries(session);
      setState(() => _refreshRecentConversations(session.username));
    }
  }

  Future<void> _signOut() async {
    await _client.disconnect();
    await _groupClient.disconnect();
    setState(() {
      _groupChatActive = false;
      _activeConversationKey = null;
      _activeGroup = null;
      _session = null;
      _messages.clear();
      _groups.clear();
      _recentConversations.clear();
      _mailboxSummaries.clear();
      _logs.clear();
      _passwordController.clear();
    });
  }

  Future<void> _loadGroups(AuthSession session) async {
    setState(() => _groupsBusy = true);
    try {
      final groups = await listGroups(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
      );
      if (mounted) {
        setState(() {
          _groups
            ..clear()
            ..addAll(groups);
        });
      }
    } catch (error) {
      _addLog('Could not load groups: $error');
    } finally {
      if (mounted) {
        setState(() => _groupsBusy = false);
      }
    }
  }

  Future<void> _prepareSignedInSession(AuthSession session) async {
    try {
      await ensureIdentityKeyPublished(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        session: session,
      );
      _addLog('Identity key ready.');
    } catch (error) {
      _addLog('Could not publish identity key: $error');
    }
    await _loadGroups(session);
    await _loadMailboxSummaries(session);
    if (mounted) {
      setState(() => _refreshRecentConversations(session.username));
    }
  }

  Future<void> _loadMailboxSummaries(AuthSession session) async {
    try {
      final summaries = await listMailboxSummaries(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
      );
      if (mounted) {
        setState(() {
          _mailboxSummaries
            ..clear()
            ..addAll(summaries);
        });
      }
    } catch (error) {
      _addLog('Could not load unread chats: $error');
    }
  }

  Future<void> _createGroup() async {
    final session = _session;
    if (session == null) {
      _addLog('Sign in before creating a group.');
      return;
    }

    final members = _groupMembersController.text
        .split(RegExp(r'[\s,]+'))
        .map((member) => member.trim().toLowerCase())
        .where((member) => member.isNotEmpty)
        .toList(growable: false);
    if (_groupNameController.text.trim().isEmpty || members.isEmpty) {
      _addLog('Enter a group name and at least one member username.');
      return;
    }

    setState(() => _groupsBusy = true);
    try {
      final group = await createGroup(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
        name: _groupNameController.text.trim(),
        members: members,
      );
      await ensureGroupKeyPublished(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        session: session,
        group: group,
      );
      setState(() {
        _groups.insert(0, group);
        _groupNameController.clear();
        _groupMembersController.clear();
      });
      _addLog('Group created: ${group.name}.');
    } catch (error) {
      _addLog('Group create failed: $error');
    } finally {
      if (mounted) {
        setState(() => _groupsBusy = false);
      }
    }
  }

  Future<void> _openGroup(GroupSummary group) async {
    final session = _session;
    if (session == null) {
      _addLog('Sign in before opening a group.');
      return;
    }

    FocusScope.of(context).unfocus();
    final conversationKey = 'group:${group.id}';
    final history = loadMessageHistory(conversationKey);
    try {
      final groupKeyBase64 = await loadOrFetchGroupKey(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        session: session,
        group: group,
      );
      await _client.disconnect();
      setState(() {
        _groupChatActive = true;
        _activeTitle = group.name;
        _activeSubtitle = '${group.members.length} members';
        _activeConversationKey = conversationKey;
        _activeGroup = group;
        _messages
          ..clear()
          ..addAll(history);
      });
      await _groupClient.connect(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
        groupId: group.id,
        groupKeyBase64: groupKeyBase64,
      );
    } catch (error) {
      setState(() => _status = PeerStatus.failed);
      _addLog('Open group failed: $error');
    }
  }

  void _toggleCamera() {
    if (_groupChatActive) {
      unawaited(_groupClient.setCameraEnabled(!_groupClient.cameraEnabled));
      return;
    }
    unawaited(_client.setCameraEnabled(!_client.cameraEnabled));
  }

  void _openChatListEntry(_ChatListEntry entry) {
    _contactController.text = entry.contactUsername;
    unawaited(_connect());
  }

  void _toggleMicrophone() {
    if (_groupChatActive) {
      unawaited(
        _groupClient.setMicrophoneEnabled(!_groupClient.microphoneEnabled),
      );
      return;
    }
    unawaited(_client.setMicrophoneEnabled(!_client.microphoneEnabled));
  }

  void _toggleScreenShare() {
    if (_groupChatActive) {
      unawaited(
        _groupClient.setScreenShareEnabled(!_groupClient.screenShareEnabled),
      );
      return;
    }
    unawaited(_client.setScreenShareEnabled(!_client.screenShareEnabled));
  }

  void _startCall() {
    if (_groupChatActive) {
      final session = _session;
      final group = _activeGroup;
      if (session == null || group == null) {
        _addLog('Open a group before starting a group call.');
        return;
      }
      unawaited(
        _groupClient.startConference(
          signalingUri: Uri.parse(_signalingController.text.trim()),
          token: session.token,
          groupId: group.id,
        ),
      );
      return;
    }
    _client.startCall();
  }

  void _acceptCall() {
    unawaited(_client.acceptCall());
  }

  void _declineCall() {
    _client.declineCall();
  }

  void _endCall() {
    if (_groupChatActive) {
      unawaited(_groupClient.endConference());
      return;
    }
    unawaited(_client.endCall());
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    if (_groupChatActive) {
      _groupClient.send(text);
    } else {
      _client.send(text);
    }
    _messageController.clear();
    _scrollToEnd();
  }

  void _sendAttachment() {
    if (_groupChatActive) {
      _addLog('Group attachments are not available yet.');
      return;
    }
    unawaited(_client.pickAndSendAttachment());
  }

  void _addLog(String message) {
    setState(() {
      _logs
        ..add(message)
        ..removeRange(0, _logs.length > 80 ? _logs.length - 80 : 0);
    });
  }

  void _saveActiveHistory() {
    final conversationKey = _activeConversationKey;
    if (conversationKey == null) {
      return;
    }

    saveMessageHistory(conversationKey, _messages);
    final session = _session;
    if (session != null) {
      _refreshRecentConversations(session.username);
    }
  }

  void _refreshRecentConversations(String username) {
    _recentConversations
      ..clear()
      ..addAll(listStoredDirectConversations(username));
  }

  List<_ChatListEntry> _chatListEntries() {
    final entriesByContact = <String, _ChatListEntry>{};
    for (final conversation in _recentConversations) {
      entriesByContact[conversation.contactUsername] = _ChatListEntry(
        contactUsername: conversation.contactUsername,
        lastText: conversation.lastText,
        updatedAt: conversation.updatedAt,
        unreadCount: 0,
      );
    }

    for (final summary in _mailboxSummaries) {
      final existing = entriesByContact[summary.contactUsername];
      entriesByContact[summary.contactUsername] = _ChatListEntry(
        contactUsername: summary.contactUsername,
        lastText: summary.unreadCount == 1
            ? 'New encrypted message'
            : '${summary.unreadCount} new encrypted messages',
        updatedAt:
            existing != null && existing.updatedAt.isAfter(summary.updatedAt)
            ? existing.updatedAt
            : summary.updatedAt,
        unreadCount: summary.unreadCount,
      );
    }

    final entries = entriesByContact.values.toList(growable: false);
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries;
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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final colorScheme = Theme.of(context).colorScheme;
            final wide = constraints.maxWidth >= 860;
            if (!_isConnected) {
              if (_session == null) {
                return SingleChildScrollView(
                  padding: EdgeInsets.all(wide ? 32 : 16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: _AccountPanel(
                        signalingController: _signalingController,
                        emailController: _emailController,
                        usernameController: _usernameController,
                        passwordController: _passwordController,
                        busy: _authBusy,
                        onCreateAccount: _createAccount,
                        onSignIn: _signIn,
                        logs: _logs,
                      ),
                    ),
                  ),
                );
              }

              return _ContactPanel(
                signalingController: _signalingController,
                contactController: _contactController,
                groupNameController: _groupNameController,
                groupMembersController: _groupMembersController,
                session: _session!,
                chatEntries: _chatListEntries(),
                groups: _groups,
                connecting:
                    _status == PeerStatus.signaling ||
                    _status == PeerStatus.waitingForPeer ||
                    _status == PeerStatus.connecting,
                groupsBusy: _groupsBusy,
                onConnect: _connect,
                onOpenChatEntry: _openChatListEntry,
                onCreateGroup: _createGroup,
                onOpenGroup: _openGroup,
                onRefreshGroups: () {
                  final session = _session;
                  if (session != null) {
                    unawaited(_loadGroups(session));
                  }
                },
                onSignOut: _signOut,
                logs: _logs,
              );
            }

            final activeCallState = _groupChatActive
                ? _groupClient.callState
                : _client.callState;
            final activeCameraEnabled = _groupChatActive
                ? _groupClient.cameraEnabled
                : _client.cameraEnabled;
            final activeMicrophoneEnabled = _groupChatActive
                ? _groupClient.microphoneEnabled
                : _client.microphoneEnabled;
            final activeScreenShareEnabled = _groupChatActive
                ? _groupClient.screenShareEnabled
                : _client.screenShareEnabled;
            final chatHeader = _ChatHeader(
              room: _activeTitle,
              peer: _activeSubtitle,
              statusLabel: _statusLabel(),
              statusColor: _statusColor(colorScheme),
              cameraEnabled: activeCameraEnabled,
              microphoneEnabled: activeMicrophoneEnabled,
              screenShareEnabled: activeScreenShareEnabled,
              encryptionReady: _groupChatActive
                  ? true
                  : _client.encryptionReady,
              callState: activeCallState,
              callsAvailable: true,
              onBack: _disconnect,
              onStartCall: _startCall,
              onEndCall: _endCall,
              onToggleCamera: _toggleCamera,
              onToggleMicrophone: _toggleMicrophone,
              onToggleScreenShare: _toggleScreenShare,
            );
            final callNotice = _CallNotice(
              callState: activeCallState,
              onAccept: _acceptCall,
              onDecline: _declineCall,
              onEnd: _endCall,
            );
            final call = _CallPanel(
              localVideoViewType: _groupChatActive
                  ? _groupClient.localVideoViewType
                  : _client.localVideoViewType,
              remoteVideoViews: _groupChatActive
                  ? _groupClient.remoteVideoViews
                  : [
                      MediaView(
                        title: 'Remote',
                        viewType: _client.remoteVideoViewType,
                      ),
                    ],
              connected: _isConnected,
            );
            final chat = _ChatPanel(
              messages: _messages,
              scrollController: _scrollController,
              messageController: _messageController,
              canType: _isConnected,
              canSend: _groupChatActive
                  ? _groupClient.canSend
                  : _client.canMessage,
              canAttach: !_groupChatActive && _client.canMessage,
              onSend: _sendMessage,
              onAttach: _sendAttachment,
            );

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1440),
                child: Padding(
                  padding: EdgeInsets.all(wide ? 24 : 12),
                  child: Column(
                    children: [
                      chatHeader,
                      if (activeCallState == CallState.incoming ||
                          activeCallState == CallState.outgoing) ...[
                        const SizedBox(height: 12),
                        callNotice,
                      ],
                      if (activeCallState == CallState.active) ...[
                        const SizedBox(height: 12),
                        SizedBox(height: wide ? 320 : 260, child: call),
                      ],
                      const SizedBox(height: 12),
                      Expanded(child: chat),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _statusLabel() {
    if (_groupChatActive ? _groupClient.canSend : _client.canSend) {
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
    if (_groupChatActive ? _groupClient.canSend : _client.canSend) {
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
    required this.screenShareEnabled,
    required this.encryptionReady,
    required this.callState,
    required this.callsAvailable,
    required this.onBack,
    required this.onStartCall,
    required this.onEndCall,
    required this.onToggleCamera,
    required this.onToggleMicrophone,
    required this.onToggleScreenShare,
  });

  final String room;
  final String peer;
  final String statusLabel;
  final Color statusColor;
  final bool cameraEnabled;
  final bool microphoneEnabled;
  final bool screenShareEnabled;
  final bool encryptionReady;
  final CallState callState;
  final bool callsAvailable;
  final VoidCallback onBack;
  final VoidCallback onStartCall;
  final VoidCallback onEndCall;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleMicrophone;
  final VoidCallback onToggleScreenShare;

  @override
  Widget build(BuildContext context) {
    final initial = (room.isEmpty ? 'P' : room.characters.first).toUpperCase();
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          room.isEmpty ? 'Direct chat' : room,
          style: Theme.of(context).textTheme.titleLarge,
          overflow: TextOverflow.ellipsis,
        ),
        if (peer.isNotEmpty)
          Text(
            peer,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
    final statusChip = _StatusPill(label: statusLabel, color: statusColor);
    final privacyChip = Tooltip(
      message: encryptionReady
          ? 'End-to-end encryption is active'
          : 'Preparing end-to-end encryption',
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: encryptionReady
              ? const Color(0xffecfdf3)
              : const Color(0xfffffaeb),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              encryptionReady ? Icons.lock_rounded : Icons.lock_clock_rounded,
              size: 15,
              color: encryptionReady ? _Ui.success : _Ui.warning,
            ),
            const SizedBox(width: 6),
            Text(
              encryptionReady ? 'Encrypted' : 'Securing',
              style: TextStyle(
                color: encryptionReady ? _Ui.success : _Ui.warning,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
    final callControls = <Widget>[
      if (callsAvailable && callState == CallState.active) ...[
        _RoundActionButton(
          onPressed: onToggleMicrophone,
          icon: microphoneEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
          tooltip: microphoneEnabled ? 'Mute microphone' : 'Unmute audio',
          selected: microphoneEnabled,
        ),
        const SizedBox(width: 8),
        _RoundActionButton(
          onPressed: onToggleCamera,
          icon: cameraEnabled
              ? Icons.videocam_rounded
              : Icons.videocam_off_rounded,
          tooltip: cameraEnabled ? 'Turn camera off' : 'Start video',
          selected: cameraEnabled,
        ),
        const SizedBox(width: 8),
        _RoundActionButton(
          onPressed: onToggleScreenShare,
          icon: screenShareEnabled
              ? Icons.stop_screen_share_rounded
              : Icons.screen_share_rounded,
          tooltip: screenShareEnabled ? 'Stop sharing screen' : 'Share screen',
          selected: screenShareEnabled,
        ),
        const SizedBox(width: 8),
      ],
      if (callsAvailable)
        _RoundActionButton(
          onPressed: callState == CallState.idle ? onStartCall : onEndCall,
          icon: callState == CallState.idle
              ? Icons.call_rounded
              : Icons.call_end_rounded,
          tooltip: callState == CallState.idle ? 'Start call' : 'End call',
          emphasized: true,
          destructive: callState != CallState.idle,
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0a101828),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identity = Row(
            children: [
              _RoundActionButton(
                onPressed: onBack,
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back to conversations',
              ),
              const SizedBox(width: 10),
              CircleAvatar(
                radius: 22,
                backgroundColor: _Ui.primarySoft,
                foregroundColor: _Ui.primary,
                child: Text(
                  initial,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: titleBlock),
            ],
          );

          if (constraints.maxWidth < 720) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: identity),
                    if (callState != CallState.active) ...callControls,
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [statusChip, const SizedBox(width: 8), privacyChip],
                ),
                if (callState == CallState.active) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: callControls,
                    ),
                  ),
                ],
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: identity),
              statusChip,
              const SizedBox(width: 8),
              privacyChip,
              const SizedBox(width: 16),
              ...callControls,
            ],
          );
        },
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.onPressed,
    required this.icon,
    required this.tooltip,
    this.selected = false,
    this.emphasized = false,
    this.destructive = false,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool emphasized;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final background = destructive
        ? _Ui.danger
        : emphasized
        ? _Ui.primary
        : selected
        ? _Ui.primarySoft
        : const Color(0xfff2f4f7);
    final foreground = destructive || emphasized
        ? Colors.white
        : selected
        ? _Ui.primary
        : _Ui.muted;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: const Color(0xfff2f4f7),
        disabledForegroundColor: _Ui.subtle,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identity = Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _Ui.primarySoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  incoming
                      ? Icons.call_received_rounded
                      : Icons.call_made_rounded,
                  color: _Ui.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incoming ? 'Incoming call' : 'Calling…',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      incoming
                          ? 'Someone would like to connect'
                          : 'Waiting for an answer',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (incoming) ...[
                OutlinedButton.icon(
                  onPressed: onDecline,
                  icon: const Icon(Icons.call_end_rounded, size: 18),
                  label: const Text('Decline'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.call_rounded, size: 18),
                  label: const Text('Accept'),
                ),
              ] else
                OutlinedButton.icon(
                  onPressed: onEnd,
                  icon: const Icon(Icons.call_end_rounded, size: 18),
                  label: const Text('Cancel'),
                ),
            ],
          );

          if (constraints.maxWidth < 560) {
            return Column(
              children: [
                identity,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: identity),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel({
    required this.localVideoViewType,
    required this.remoteVideoViews,
    required this.connected,
  });

  final String? localVideoViewType;
  final List<MediaView> remoteVideoViews;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final remoteViews = remoteVideoViews.isEmpty
        ? const [MediaView(title: 'Remote', viewType: null)]
        : remoteVideoViews;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xff101828),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final remoteGrid = _RemoteVideoGrid(
              views: remoteViews,
              connected: connected,
            );
            final localTile = _VideoTile(
              title: 'You',
              viewType: localVideoViewType,
              placeholder: connected ? 'Starting camera' : 'Local preview',
            );

            if (constraints.maxWidth < 680) {
              return Column(
                children: [
                  Expanded(child: remoteGrid),
                  const SizedBox(height: 10),
                  SizedBox(height: 120, child: localTile),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: remoteGrid),
                const SizedBox(width: 10),
                SizedBox(width: 240, child: localTile),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RemoteVideoGrid extends StatelessWidget {
  const _RemoteVideoGrid({required this.views, required this.connected});

  final List<MediaView> views;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = views.length <= 1 ? 1 : 2;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 16 / 9,
      ),
      itemCount: views.length,
      itemBuilder: (context, index) {
        final view = views[index];
        return _VideoTile(
          title: view.title,
          viewType: view.viewType,
          placeholder: connected
              ? 'Waiting for remote video'
              : 'Connect to start a call',
        );
      },
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
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xff0b0f1a),
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

enum _AuthMode { signIn, createAccount }

class _AccountPanel extends StatefulWidget {
  const _AccountPanel({
    required this.signalingController,
    required this.emailController,
    required this.usernameController,
    required this.passwordController,
    required this.busy,
    required this.onCreateAccount,
    required this.onSignIn,
    required this.logs,
  });

  final TextEditingController signalingController;
  final TextEditingController emailController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool busy;
  final VoidCallback onCreateAccount;
  final VoidCallback onSignIn;
  final List<String> logs;

  @override
  State<_AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<_AccountPanel> {
  _AuthMode _mode = _AuthMode.signIn;

  void _submit() {
    if (_mode == _AuthMode.signIn) {
      widget.onSignIn();
    } else {
      widget.onCreateAccount();
    }
  }

  @override
  Widget build(BuildContext context) {
    final brandPanel = Container(
      constraints: const BoxConstraints(minHeight: 520),
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff5b55e7), Color(0xff3730a3)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x224f46e5),
            blurRadius: 32,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -75,
            top: -75,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x22ffffff), width: 36),
              ),
            ),
          ),
          Positioned(
            left: -90,
            bottom: -120,
            child: Container(
              width: 280,
              height: 280,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0x0dffffff),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _BrandLockup(light: true),
              const SizedBox(height: 72),
              const Text(
                'Private conversations,\ngenuinely yours.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  height: 1.12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Direct, end-to-end encrypted messaging with calls and groups — without giving up control.',
                style: TextStyle(
                  color: Color(0xffd7d5ff),
                  fontSize: 16,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 32),
              const Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  _FeatureCheck(label: 'End-to-end encrypted'),
                  _FeatureCheck(label: 'Peer-to-peer calls'),
                  _FeatureCheck(label: 'No tracking'),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    final formPanel = Container(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 520 ? 22 : 40),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0d101828),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _mode == _AuthMode.signIn ? 'Welcome back' : 'Join Peep',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            _mode == _AuthMode.signIn
                ? 'Sign in to continue to your conversations.'
                : 'Create an account to start a private conversation.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _Ui.muted),
          ),
          const SizedBox(height: 28),
          _AuthModeSwitch(
            value: _mode,
            enabled: !widget.busy,
            onChanged: (mode) => setState(() => _mode = mode),
          ),
          const SizedBox(height: 24),
          if (_mode == _AuthMode.createAccount) ...[
            TextField(
              controller: widget.emailController,
              enabled: !widget.busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email address',
                hintText: 'you@example.com',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: widget.usernameController,
            enabled: !widget.busy,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: 'Username',
              hintText: 'Your username',
              prefixIcon: Icon(Icons.alternate_email_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: widget.passwordController,
            enabled: !widget.busy,
            obscureText: true,
            onSubmitted: widget.busy ? null : (_) => _submit(),
            autofillHints: [
              _mode == _AuthMode.signIn
                  ? AutofillHints.password
                  : AutofillHints.newPassword,
            ],
            decoration: const InputDecoration(
              labelText: 'Password',
              hintText: 'Enter your password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          _ConnectionSettings(
            controller: widget.signalingController,
            enabled: !widget.busy,
          ),
          if (widget.logs.isNotEmpty) ...[
            const SizedBox(height: 14),
            _InlineNotice(message: widget.logs.last),
          ],
          const SizedBox(height: 22),
          FilledButton(
            onPressed: widget.busy ? null : _submit,
            child: widget.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _mode == _AuthMode.signIn
                            ? 'Sign in securely'
                            : 'Create my account',
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_forward_rounded, size: 18),
                    ],
                  ),
          ),
          const SizedBox(height: 18),
          Text(
            'Your messages are encrypted before they leave your device.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 860) {
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 20, top: 4),
                child: _BrandLockup(),
              ),
              formPanel,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 11, child: brandPanel),
            const SizedBox(width: 28),
            Expanded(flex: 9, child: formPanel),
          ],
        );
      },
    );
  }
}

class _AuthModeSwitch extends StatelessWidget {
  const _AuthModeSwitch({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final _AuthMode value;
  final bool enabled;
  final ValueChanged<_AuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xfff2f4f7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final mode in _AuthMode.values)
            Expanded(
              child: Material(
                color: mode == value ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                elevation: mode == value ? 1 : 0,
                shadowColor: const Color(0x1a101828),
                child: InkWell(
                  onTap: enabled ? () => onChanged(mode) : null,
                  borderRadius: BorderRadius.circular(10),
                  child: Center(
                    child: Text(
                      mode == _AuthMode.signIn ? 'Sign in' : 'Create account',
                      style: TextStyle(
                        color: mode == value ? _Ui.ink : _Ui.muted,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectionSettings extends StatelessWidget {
  const _ConnectionSettings({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 2),
      childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(Icons.tune_rounded, size: 20, color: _Ui.muted),
      title: const Text(
        'Connection settings',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      subtitle: const Text('Advanced', style: TextStyle(fontSize: 11)),
      children: [
        TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Signaling server URL',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final isError =
        message.toLowerCase().contains('error') ||
        message.toLowerCase().contains('failed') ||
        message.toLowerCase().contains('could not');
    final color = isError ? _Ui.danger : _Ui.success;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCheck extends StatelessWidget {
  const _FeatureCheck({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.check_circle_rounded,
          color: Color(0xffa5f3fc),
          size: 18,
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup({this.light = false});

  final bool light;

  @override
  Widget build(BuildContext context) {
    final foreground = light ? Colors.white : _Ui.ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: light ? Colors.white : _Ui.primary,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.chat_bubble_rounded,
            color: light ? _Ui.primary : Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: 11),
        Text(
          'peep',
          style: TextStyle(
            color: foreground,
            fontSize: 25,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
        ),
      ],
    );
  }
}

class _ContactPanel extends StatelessWidget {
  const _ContactPanel({
    required this.signalingController,
    required this.contactController,
    required this.groupNameController,
    required this.groupMembersController,
    required this.session,
    required this.chatEntries,
    required this.groups,
    required this.connecting,
    required this.groupsBusy,
    required this.onConnect,
    required this.onOpenChatEntry,
    required this.onCreateGroup,
    required this.onOpenGroup,
    required this.onRefreshGroups,
    required this.onSignOut,
    required this.logs,
  });

  final TextEditingController signalingController;
  final TextEditingController contactController;
  final TextEditingController groupNameController;
  final TextEditingController groupMembersController;
  final AuthSession session;
  final List<_ChatListEntry> chatEntries;
  final List<GroupSummary> groups;
  final bool connecting;
  final bool groupsBusy;
  final VoidCallback onConnect;
  final void Function(_ChatListEntry entry) onOpenChatEntry;
  final VoidCallback onCreateGroup;
  final void Function(GroupSummary group) onOpenGroup;
  final VoidCallback onRefreshGroups;
  final VoidCallback onSignOut;
  final List<String> logs;

  void _showNewChatDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ActionDialog(
        icon: Icons.edit_square,
        title: 'New conversation',
        description: 'Enter a Peep username to start a private chat.',
        primaryLabel: connecting ? 'Connecting…' : 'Start conversation',
        primaryEnabled: !connecting,
        onPrimary: () {
          Navigator.of(dialogContext).pop();
          onConnect();
        },
        child: TextField(
          controller: contactController,
          autofocus: true,
          enabled: !connecting,
          textInputAction: TextInputAction.done,
          onSubmitted: connecting
              ? null
              : (_) {
                  Navigator.of(dialogContext).pop();
                  onConnect();
                },
          decoration: const InputDecoration(
            labelText: 'Username',
            hintText: 'e.g. alex',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
      ),
    );
  }

  void _showCreateGroupDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ActionDialog(
        icon: Icons.group_add_rounded,
        title: 'Create a group',
        description: 'Bring several people into one encrypted conversation.',
        primaryLabel: groupsBusy ? 'Creating…' : 'Create group',
        primaryEnabled: !groupsBusy,
        onPrimary: () {
          Navigator.of(dialogContext).pop();
          onCreateGroup();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: groupNameController,
              autofocus: true,
              enabled: !groupsBusy,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'e.g. Design team',
                prefixIcon: Icon(Icons.groups_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: groupMembersController,
              enabled: !groupsBusy,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Member usernames',
                hintText: 'alex, maya, sam',
                helperText: 'Separate usernames with commas',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showConnectionDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ActionDialog(
        icon: Icons.hub_outlined,
        title: 'Connection settings',
        description: 'Choose the signaling server used to establish sessions.',
        primaryLabel: 'Save settings',
        onPrimary: () => Navigator.of(dialogContext).pop(),
        child: TextField(
          controller: signalingController,
          enabled: !connecting,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Signaling server URL',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
      ),
    );
  }

  void _showActivityDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ActionDialog(
        icon: Icons.terminal_rounded,
        title: 'Connection activity',
        description: 'Technical session events for troubleshooting.',
        primaryLabel: 'Done',
        onPrimary: () => Navigator.of(dialogContext).pop(),
        child: _EventLog(logs: logs),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversationSurface = _ConversationSurface(
      chatEntries: chatEntries,
      groups: groups,
      connecting: connecting,
      groupsBusy: groupsBusy,
      onOpenChatEntry: onOpenChatEntry,
      onOpenGroup: onOpenGroup,
      onRefreshGroups: onRefreshGroups,
      onNewChat: () => _showNewChatDialog(context),
      onNewGroup: () => _showCreateGroupDialog(context),
    );

    return Column(
      children: [
        Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: _Ui.border)),
          ),
          child: Row(
            children: [
              const _BrandLockup(),
              const Spacer(),
              if (connecting) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Connecting…',
                  style: TextStyle(color: _Ui.muted, fontSize: 13),
                ),
                const SizedBox(width: 16),
              ],
              _RoundActionButton(
                onPressed: connecting
                    ? null
                    : () => _showNewChatDialog(context),
                icon: Icons.add_comment_rounded,
                tooltip: 'New conversation',
                emphasized: true,
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 780) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _MobileProfileCard(
                        session: session,
                        onSignOut: connecting ? null : onSignOut,
                      ),
                      const SizedBox(height: 16),
                      _MobileQuickActions(
                        onNewChat: connecting
                            ? null
                            : () => _showNewChatDialog(context),
                        onNewGroup: groupsBusy
                            ? null
                            : () => _showCreateGroupDialog(context),
                      ),
                      const SizedBox(height: 16),
                      conversationSurface,
                      const SizedBox(height: 16),
                      _PrivacyCard(
                        onConnectionSettings: () =>
                            _showConnectionDialog(context),
                        onActivity: () => _showActivityDialog(context),
                      ),
                    ],
                  ),
                );
              }

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 244,
                          child: _HomeSidebar(
                            session: session,
                            connecting: connecting,
                            onConnectionSettings: () =>
                                _showConnectionDialog(context),
                            onActivity: () => _showActivityDialog(context),
                            onSignOut: onSignOut,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(child: conversationSurface),
                        if (constraints.maxWidth >= 1100) ...[
                          const SizedBox(width: 20),
                          SizedBox(
                            width: 292,
                            child: _HomeActionsPanel(
                              onNewChat: connecting
                                  ? null
                                  : () => _showNewChatDialog(context),
                              onNewGroup: groupsBusy
                                  ? null
                                  : () => _showCreateGroupDialog(context),
                              onConnectionSettings: () =>
                                  _showConnectionDialog(context),
                              onActivity: () => _showActivityDialog(context),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ActionDialog extends StatelessWidget {
  const _ActionDialog({
    required this.icon,
    required this.title,
    required this.description,
    required this.primaryLabel,
    required this.onPrimary,
    required this.child,
    this.primaryEnabled = true,
  });

  final IconData icon;
  final String title;
  final String description;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final Widget child;
  final bool primaryEnabled;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _Ui.primarySoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: _Ui.primary, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              child,
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: primaryEnabled ? onPrimary : null,
                      child: Text(primaryLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationSurface extends StatelessWidget {
  const _ConversationSurface({
    required this.chatEntries,
    required this.groups,
    required this.connecting,
    required this.groupsBusy,
    required this.onOpenChatEntry,
    required this.onOpenGroup,
    required this.onRefreshGroups,
    required this.onNewChat,
    required this.onNewGroup,
  });

  final List<_ChatListEntry> chatEntries;
  final List<GroupSummary> groups;
  final bool connecting;
  final bool groupsBusy;
  final void Function(_ChatListEntry entry) onOpenChatEntry;
  final void Function(GroupSummary group) onOpenGroup;
  final VoidCallback onRefreshGroups;
  final VoidCallback onNewChat;
  final VoidCallback onNewGroup;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Recent conversations',
          count: chatEntries.length,
          actionLabel: 'New message',
          actionIcon: Icons.add_rounded,
          onAction: connecting ? null : onNewChat,
        ),
        const SizedBox(height: 12),
        _RecentChatList(
          entries: chatEntries,
          connecting: connecting,
          onOpenEntry: onOpenChatEntry,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 22),
          child: Divider(height: 1),
        ),
        _SectionHeader(
          title: 'Groups',
          count: groups.length,
          actionLabel: 'Create group',
          actionIcon: Icons.group_add_outlined,
          onAction: groupsBusy ? null : onNewGroup,
          trailing: IconButton(
            onPressed: groupsBusy ? null : onRefreshGroups,
            icon: groupsBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Refresh groups',
          ),
        ),
        const SizedBox(height: 12),
        _GroupList(groups: groups, busy: groupsBusy, onOpenGroup: onOpenGroup),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08101828),
            blurRadius: 18,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final header = Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Messages',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 5),
                Text(
                  'Your private conversations in one place.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: _Ui.muted),
                ),
              ],
            ),
          );

          if (!constraints.hasBoundedHeight) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                    child: content,
                  ),
                ],
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: content,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.trailing,
  });

  final String title;
  final int count;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xfff2f4f7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: _Ui.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        ?trailing,
        TextButton.icon(
          onPressed: onAction,
          icon: Icon(actionIcon, size: 17),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

class _HomeSidebar extends StatelessWidget {
  const _HomeSidebar({
    required this.session,
    required this.connecting,
    required this.onConnectionSettings,
    required this.onActivity,
    required this.onSignOut,
  });

  final AuthSession session;
  final bool connecting;
  final VoidCallback onConnectionSettings;
  final VoidCallback onActivity;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CircleAvatar(
            radius: 31,
            backgroundColor: _Ui.primarySoft,
            foregroundColor: _Ui.primary,
            child: Text(
              session.username.characters.first.toUpperCase(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '@${session.username}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            session.email,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 20),
          const _SecureIdentityBadge(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Divider(height: 1),
          ),
          const Text(
            'YOUR SPACE',
            style: TextStyle(
              color: _Ui.subtle,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          const _SidebarDestination(
            icon: Icons.chat_bubble_rounded,
            label: 'Messages',
            selected: true,
          ),
          const _SidebarDestination(
            icon: Icons.groups_rounded,
            label: 'Groups',
          ),
          const Spacer(),
          _SidebarButton(
            icon: Icons.hub_outlined,
            label: 'Connection settings',
            onTap: onConnectionSettings,
          ),
          _SidebarButton(
            icon: Icons.terminal_rounded,
            label: 'Activity',
            onTap: onActivity,
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: connecting ? null : onSignOut,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.icon,
    required this.label,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: selected ? _Ui.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: selected ? _Ui.primary : _Ui.muted),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: selected ? _Ui.primary : _Ui.muted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _Ui.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _Ui.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecureIdentityBadge extends StatelessWidget {
  const _SecureIdentityBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xffecfdf3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.verified_user_rounded, size: 17, color: _Ui.success),
          SizedBox(width: 7),
          Flexible(
            child: Text(
              'Secure identity ready',
              style: TextStyle(
                color: _Ui.success,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeActionsPanel extends StatelessWidget {
  const _HomeActionsPanel({
    required this.onNewChat,
    required this.onNewGroup,
    required this.onConnectionSettings,
    required this.onActivity,
  });

  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback onConnectionSettings;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff5b55e7), Color(0xff4338ca)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0x22ffffff),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.chat_bubble_outline_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Start a private\nconversation',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Connect directly by username.',
                style: TextStyle(color: Color(0xffd7d5ff), fontSize: 13),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onNewChat,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: _Ui.primary,
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New message'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _ActionTile(
          icon: Icons.group_add_outlined,
          title: 'Create a group',
          subtitle: 'Start a secure group space',
          onTap: onNewGroup,
        ),
        const Spacer(),
        _PrivacyCard(
          onConnectionSettings: onConnectionSettings,
          onActivity: onActivity,
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _Ui.border),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _Ui.primarySoft,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: _Ui.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _Ui.subtle),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({
    required this.onConnectionSettings,
    required this.onActivity,
  });

  final VoidCallback onConnectionSettings;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xfff8f9fc),
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_rounded, color: _Ui.success, size: 19),
              SizedBox(width: 8),
              Text(
                'Privacy protected',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Messages use end-to-end encryption and calls connect peer to peer.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: onConnectionSettings,
                child: const Text('Settings'),
              ),
              TextButton(onPressed: onActivity, child: const Text('Activity')),
            ],
          ),
        ],
      ),
    );
  }
}

class _MobileProfileCard extends StatelessWidget {
  const _MobileProfileCard({required this.session, required this.onSignOut});

  final AuthSession session;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 25,
          backgroundColor: _Ui.primarySoft,
          foregroundColor: _Ui.primary,
          child: Text(
            session.username.characters.first.toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${session.username}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                session.email,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onSignOut,
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout_rounded, size: 20),
        ),
      ],
    );
  }
}

class _MobileQuickActions extends StatelessWidget {
  const _MobileQuickActions({
    required this.onNewChat,
    required this.onNewGroup,
  });

  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onNewChat,
            icon: const Icon(Icons.add_comment_rounded, size: 18),
            label: const Text('New chat'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onNewGroup,
            icon: const Icon(Icons.group_add_outlined, size: 18),
            label: const Text('New group'),
          ),
        ),
      ],
    );
  }
}

class _ChatListEntry {
  const _ChatListEntry({
    required this.contactUsername,
    required this.lastText,
    required this.updatedAt,
    required this.unreadCount,
  });

  final String contactUsername;
  final String lastText;
  final DateTime updatedAt;
  final int unreadCount;
}

class _RecentChatList extends StatelessWidget {
  const _RecentChatList({
    required this.entries,
    required this.connecting,
    required this.onOpenEntry,
  });

  final List<_ChatListEntry> entries;
  final bool connecting;
  final void Function(_ChatListEntry entry) onOpenEntry;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const _EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No conversations yet',
        message: 'Start a new message and it will appear here.',
      );
    }

    return Column(
      children: [
        for (final entry in entries.take(10)) ...[
          Material(
            color: entry.unreadCount > 0
                ? const Color(0xfff5f7ff)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: connecting ? null : () => onOpenEntry(entry),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    _InitialAvatar(
                      label: entry.contactUsername,
                      unread: entry.unreadCount > 0,
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.contactUsername,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _Ui.ink,
                              fontSize: 14,
                              fontWeight: entry.unreadCount > 0
                                  ? FontWeight.w800
                                  : FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            entry.lastText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: entry.unreadCount > 0
                                  ? _Ui.ink
                                  : _Ui.muted,
                              fontSize: 12,
                              fontWeight: entry.unreadCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ChatListTrailing(
                      updatedAt: entry.updatedAt,
                      unreadCount: entry.unreadCount,
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: _Ui.subtle,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (entry != entries.take(10).last)
            const Padding(
              padding: EdgeInsets.only(left: 66),
              child: Divider(height: 1),
            ),
        ],
      ],
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({required this.label, this.unread = false});

  final String label;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final safeLabel = label.trim().isEmpty ? '?' : label.trim();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 23,
          backgroundColor: _Ui.primarySoft,
          foregroundColor: _Ui.primary,
          child: Text(
            safeLabel.characters.first.toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        if (unread)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: _Ui.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xfff9fafb),
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: _Ui.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _Ui.primary, size: 20),
          ),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 3),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ChatListTrailing extends StatelessWidget {
  const _ChatListTrailing({required this.updatedAt, required this.unreadCount});

  final DateTime updatedAt;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final time = Text(
      _compactTime(updatedAt),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
    );
    if (unreadCount <= 0) {
      return time;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        time,
        const SizedBox(height: 4),
        Container(
          constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: _Ui.primary,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            unreadCount > 99 ? '99+' : unreadCount.toString(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.busy,
    required this.onOpenGroup,
  });

  final List<GroupSummary> groups;
  final bool busy;
  final void Function(GroupSummary group) onOpenGroup;

  @override
  Widget build(BuildContext context) {
    if (busy && groups.isEmpty) {
      return const SizedBox(
        height: 92,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (groups.isEmpty) {
      return const _EmptyState(
        icon: Icons.groups_outlined,
        title: 'No groups yet',
        message: 'Create a group for an encrypted shared space.',
      );
    }

    return Column(
      children: [
        for (final group in groups) ...[
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: busy ? null : () => onOpenGroup(group),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xffecfdf3),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.groups_rounded,
                        color: _Ui.success,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.name,
                            style: Theme.of(context).textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${group.members.length} members  •  Encrypted',
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: busy ? null : () => onOpenGroup(group),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                      tooltip: 'Open ${group.name}',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (group != groups.last)
            const Padding(
              padding: EdgeInsets.only(left: 66),
              child: Divider(height: 1),
            ),
        ],
      ],
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xff171b2b),
        borderRadius: BorderRadius.circular(16),
      ),
      child: logs.isEmpty
          ? const Center(
              child: Text(
                'No activity to show yet.',
                style: TextStyle(color: Color(0xff98a2b3), fontSize: 12),
              ),
            )
          : ListView.separated(
              itemCount: logs.length,
              separatorBuilder: (context, index) => const SizedBox(height: 5),
              itemBuilder: (context, index) => Text(
                '› ${logs[index]}',
                style: const TextStyle(
                  color: Color(0xffd0d5dd),
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ),
    );
  }
}

String _directRoom(String first, String second) {
  final a = first.trim().toLowerCase();
  final b = second.trim().toLowerCase();
  return a.compareTo(b) <= 0 ? 'dm:$a:$b' : 'dm:$b:$a';
}

String _compactTime(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  if (now.year == local.year &&
      now.month == local.month &&
      now.day == local.day) {
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
  if (now.year == local.year) {
    return '${local.month}/${local.day}';
  }
  return '${local.month}/${local.day}/${local.year}';
}

class _ChatPanel extends StatelessWidget {
  const _ChatPanel({
    required this.messages,
    required this.scrollController,
    required this.messageController,
    required this.canType,
    required this.canSend,
    required this.canAttach,
    required this.onSend,
    required this.onAttach,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final TextEditingController messageController;
  final bool canType;
  final bool canSend;
  final bool canAttach;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _Ui.border),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08101828),
            blurRadius: 18,
            offset: Offset(0, 5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 42,
            color: const Color(0xfffafbfc),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                const SizedBox(width: 10),
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: _Ui.subtle,
                ),
                const SizedBox(width: 5),
                Text(
                  'Messages are end-to-end encrypted',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontSize: 10),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Divider()),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? const _ConversationEmptyState()
                : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _MessageBubble(message: message);
                    },
                  ),
          ),
          const Divider(height: 1),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _RoundActionButton(
                  onPressed: canAttach ? onAttach : null,
                  icon: Icons.attach_file_rounded,
                  tooltip: 'Attach audio or video',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xfff5f6f8),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: messageController,
                      enabled: canType,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: canType ? (_) => onSend() : null,
                      decoration: const InputDecoration(
                        hintText: 'Write a message…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _RoundActionButton(
                  onPressed: canType ? onSend : null,
                  icon: Icons.arrow_upward_rounded,
                  tooltip: canSend ? 'Send' : 'Queue until connected',
                  emphasized: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationEmptyState extends StatelessWidget {
  const _ConversationEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: _Ui.primarySoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.waving_hand_rounded,
                color: _Ui.primary,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text('Say hello', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'This is the beginning of your private conversation.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: _Ui.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final local = message.isLocal;
    final attachment = message.attachment;
    final radius = local
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(5),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          );

    return Align(
      alignment: local ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
          decoration: BoxDecoration(
            color: local ? _Ui.primary : const Color(0xfff0f2f5),
            borderRadius: radius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!local && message.sender?.isNotEmpty == true) ...[
                Text(
                  message.sender!,
                  style: const TextStyle(
                    color: _Ui.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              if (attachment == null)
                Text(
                  message.text,
                  style: TextStyle(
                    color: local ? Colors.white : _Ui.ink,
                    fontSize: 14,
                    height: 1.4,
                  ),
                )
              else
                _AttachmentBubble(attachment: attachment, isLocal: local),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    _compactTime(message.sentAt),
                    style: TextStyle(
                      color: local
                          ? Colors.white.withValues(alpha: 0.72)
                          : _Ui.subtle,
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (local) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.done_all_rounded,
                      size: 13,
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
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
