import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'ui/call_screen.dart';
import 'ui/messenger_home.dart';
import 'peer.dart';
import 'ui/account_screen.dart';
import 'ui/conversation_screen.dart';
import 'ui/peep_theme.dart';
import 'ui/interaction_feedback.dart';
import 'ui/media_settings_sheet.dart';
import 'media/media_settings.dart';
import 'models/conversation_id.dart';
import 'models/call_session.dart';
import 'models/conversation_drafts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializePlatformServices();
  runApp(const MainApp());
}

String _readableError(Object error) {
  final message = (error is StateError ? error.message : error.toString())
      .replaceFirst(
        RegExp(r'^(Exception|StateError|Invalid argument):\s*'),
        '',
      );
  return message.isEmpty ? 'Something went wrong. Please try again.' : message;
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Peep',
      debugShowCheckedModeBanner: false,
      theme: buildPeepTheme(),
      home: const PeerChatScreen(),
    );
  }
}

class PeerChatScreen extends StatefulWidget {
  const PeerChatScreen({super.key});

  @override
  State<PeerChatScreen> createState() => _PeerChatScreenState();
}

class _PeerChatScreenState extends State<PeerChatScreen>
    with WidgetsBindingObserver {
  final _signalingController = TextEditingController(
    // Android emulators reach the host machine through 10.0.2.2, not
    // localhost. This keeps a fresh mobile install connected to the local
    // Peep engine used during device testing.
    text: _defaultSignalingUrl(),
  );
  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _contactController = TextEditingController();
  final _groupNameController = TextEditingController();
  final _groupMembersController = TextEditingController();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _drafts = ConversationDrafts();

  late final PeerClient _client;
  late final GroupClient _groupClient;
  PeerStatus _status = PeerStatus.idle;
  AuthSession? _session;
  bool _authBusy = false;
  String? _authError;
  final _mediaSettingsStore = MediaSettingsStore();
  MediaSettings _mediaSettings = MediaSettings.defaults;
  bool _groupsBusy = false;
  bool _attachmentBusy = false;
  bool _openingConversation = false;
  bool _isInForeground = true;
  bool _groupChatActive = false;
  String _activeTitle = 'Direct chat';
  String _activeSubtitle = '';
  String? _activeConversationKey;
  GroupSummary? _activeGroup;
  final List<ChatMessage> _messages = [];
  final List<GroupSummary> _groups = [];
  final List<StoredConversation> _recentConversations = [];
  final List<MailboxSummary> _mailboxSummaries = [];
  final List<CallHistoryEntry> _callHistory = [];
  final _callSession = CallSessionTracker();
  bool _showCallSummary = false;
  Timer? _outgoingCallTimeout;
  final List<String> _logs = [];
  StreamSubscription<String>? _messageNotificationSubscription;
  String? _pendingNotificationContact;

  bool get _isConnected =>
      _status == PeerStatus.signaling ||
      _status == PeerStatus.waitingForPeer ||
      _status == PeerStatus.connecting ||
      _status == PeerStatus.connected;

  bool get _hasOpenConversation => _activeConversationKey != null;

  bool get _canReconnect =>
      (_status == PeerStatus.disconnected || _status == PeerStatus.failed);

  void _reconnectActiveConversation() {
    final group = _activeGroup;
    if (_groupChatActive && group != null) {
      unawaited(_openGroup(group));
      return;
    }
    unawaited(_connect());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
          if (!message.isLocal && !_isInForeground && !_groupChatActive) {
            unawaited(
              showIncomingMessageNotification(
                contact: _activeTitle,
                preview: message.text,
              ),
            );
          }
        }
      },
      onLog: _addLog,
      onMediaChanged: () {
        _onCallMediaChanged(group: false);
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
        }
      },
      onLog: _addLog,
      onMediaChanged: () {
        _onCallMediaChanged(group: true);
      },
    );
    _messageNotificationSubscription = messageNotificationTaps.listen(
      _openNotificationChat,
    );
    unawaited(_loadInitialNotificationContact());
    unawaited(_loadMediaSettings());
  }

  Future<void> _loadMediaSettings() async {
    try {
      final settings = await _mediaSettingsStore.load();
      if (!mounted) return;
      _mediaSettings = settings;
      await _client.setMediaSettings(settings);
      await _groupClient.setMediaSettings(settings);
    } catch (error) {
      _addLog('Could not restore media preferences: $error');
    }
  }

  void _showMediaSettings({bool screenOnly = false}) {
    unawaited(
      showMediaSettings(
        context,
        settings: _mediaSettings,
        loadCodecs: discoverMediaCodecs,
        inCall: _client.callActive || _groupClient.callActive,
        screenOnly: screenOnly,
        onSave: (settings) async {
          try {
            await _mediaSettingsStore.save(settings);
            if (!mounted) return 'The screen was closed.';
            setState(() => _mediaSettings = settings);
            final results = await Future.wait([
              _applyClientMediaSettings(
                () => _client.setMediaSettings(settings),
              ),
              _applyClientMediaSettings(
                () => _groupClient.setMediaSettings(settings),
              ),
            ]);
            final failures = results.whereType<String>().toList();
            if (failures.isNotEmpty) {
              return 'Preferences saved for the next call. Live limits could not be applied: ${failures.join('; ')}';
            }
            return null;
          } catch (error) {
            return _readableError(error);
          }
        },
      ),
    );
  }

  Future<String?> _applyClientMediaSettings(
    Future<void> Function() apply,
  ) async {
    try {
      await apply();
      return null;
    } catch (error) {
      return _readableError(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isInForeground = state == AppLifecycleState.resumed;
  }

  Future<void> _loadInitialNotificationContact() async {
    final contact = await takeInitialMessageNotificationContact();
    if (contact != null && contact.isNotEmpty) {
      await _openNotificationChat(contact);
    }
  }

  Future<void> _openNotificationChat(String contact) async {
    if (_session == null) {
      _pendingNotificationContact = contact;
      return;
    }
    _contactController.text = contact;
    await _connect();
  }

  @override
  void dispose() {
    _outgoingCallTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _client.disconnect();
    _groupClient.disconnect();
    _messageNotificationSubscription?.cancel();
    _signalingController.dispose();
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
    if (_authBusy) return;
    setState(() {
      _authBusy = true;
      _authError = null;
    });

    try {
      final session = await action();
      if (!mounted) return;
      setState(() {
        _session = session;
      });
      unawaited(_refreshRecentConversations(session.username));
      _addLog(successMessage);
      unawaited(_prepareSignedInSession(session));
      final notificationContact = _pendingNotificationContact;
      _pendingNotificationContact = null;
      if (notificationContact != null) {
        unawaited(_openNotificationChat(notificationContact));
      }
    } catch (error) {
      if (mounted) setState(() => _authError = _readableError(error));
      _addLog('Account error: $error');
    } finally {
      if (mounted) {
        setState(() => _authBusy = false);
      }
    }
  }

  Future<void> _connect() async {
    if (_openingConversation) return;
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

    setState(() => _openingConversation = true);
    try {
      await _groupClient.disconnect();
      final conversationKey = directConversationId(session.username, contact);
      final history = await loadMessageHistory(conversationKey);
      if (!mounted || _session != session) return;
      setState(() {
        _groupChatActive = false;
        _activeTitle = contact;
        _activeSubtitle = 'Direct message';
        _drafts.open(conversationKey, _messageController);
        _activeConversationKey = conversationKey;
        _activeGroup = null;
        _messages
          ..clear()
          ..addAll(history);
      });
      await _client.connect(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        room: conversationKey,
        peerId: session.username,
        authToken: session.token,
        accountUsername: session.username,
        contactUsername: contact,
      );
      if (mounted && _session == session) {
        setState(() {
          _mailboxSummaries.removeWhere(
            (summary) => summary.contactUsername == contact,
          );
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = PeerStatus.failed);
      }
      _addLog('Connect failed: $error');
      _showError(error);
    } finally {
      if (mounted) setState(() => _openingConversation = false);
    }
  }

  Future<void> _disconnect() async {
    _drafts.open(null, _messageController);
    _outgoingCallTimeout?.cancel();
    _outgoingCallTimeout = null;
    _callSession.reset();
    _showCallSummary = false;
    if (_groupChatActive) {
      await _groupClient.disconnect();
    } else {
      await _client.disconnect();
    }
    if (!mounted) return;
    setState(() {
      _groupChatActive = false;
      _activeConversationKey = null;
      _activeGroup = null;
      _messages.clear();
    });
    final session = _session;
    if (session != null) {
      await _loadMailboxSummaries(session);
      await _refreshRecentConversations(session.username);
    }
  }

  Future<void> _signOut() async {
    _drafts.clear(_messageController);
    _outgoingCallTimeout?.cancel();
    _outgoingCallTimeout = null;
    _callSession.reset();
    _showCallSummary = false;
    await _client.disconnect();
    await _groupClient.disconnect();
    await stopMessageNotifications();
    if (!mounted) return;
    setState(() {
      _groupChatActive = false;
      _activeConversationKey = null;
      _activeGroup = null;
      _session = null;
      _authError = null;
      _messages.clear();
      _groups.clear();
      _recentConversations.clear();
      _mailboxSummaries.clear();
      _callHistory.clear();
      _logs.clear();
      _passwordController.clear();
    });
  }

  Future<void> _loadGroups(AuthSession session) async {
    if (!mounted || _session != session) return;
    setState(() => _groupsBusy = true);
    try {
      final groups = await listGroups(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
      );
      if (mounted && _session == session) {
        setState(() {
          _groups
            ..clear()
            ..addAll(groups);
        });
      }
      for (final group in groups) {
        try {
          await republishStoredGroupKeyIfPresent(
            signalingUri: Uri.parse(_signalingController.text.trim()),
            session: session,
            group: group,
          );
        } catch (error) {
          _addLog('Could not refresh encryption for ${group.name}: $error');
        }
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
      await startMessageNotifications(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        session: session,
      );
      _addLog('Message notifications are ready.');
    } catch (error) {
      _addLog('Could not start message notifications: $error');
    }
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
      await _refreshRecentConversations(session.username);
    }
  }

  Future<void> _loadMailboxSummaries(AuthSession session) async {
    try {
      final summaries = await listMailboxSummaries(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
      );
      if (mounted && _session == session) {
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

  Future<void> _refreshHomeData() async {
    final session = _session;
    if (session == null) return;
    await Future.wait([
      _loadGroups(session),
      _loadMailboxSummaries(session),
      _refreshRecentConversations(session.username),
    ]);
  }

  Future<String?> _createGroup() async {
    final session = _session;
    if (session == null) {
      return 'Sign in before creating a group.';
    }

    final members = _groupMembersController.text
        .split(RegExp(r'[\s,]+'))
        .map((member) => member.trim().toLowerCase())
        .where((member) => member.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final name = _groupNameController.text.trim();
    if (name.isEmpty) {
      return 'Enter a group name.';
    }
    if (members.isEmpty) {
      return 'Add at least one member username.';
    }
    if (members.length == 1 && members.single == session.username) {
      return 'Add another account to create a group.';
    }

    setState(() => _groupsBusy = true);
    try {
      final group = await createGroup(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        token: session.token,
        name: name,
        members: members,
      );
      if (mounted && _session == session) {
        setState(() {
          _groups.removeWhere((existing) => existing.id == group.id);
          _groups.insert(0, group);
        });
      }
      try {
        await ensureGroupKeyPublished(
          signalingUri: Uri.parse(_signalingController.text.trim()),
          session: session,
          group: group,
        );
      } catch (error) {
        _addLog('Group encryption setup will retry: $error');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Group created. Encryption setup will retry on refresh.',
              ),
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          _groupNameController.clear();
          _groupMembersController.clear();
        });
      }
      _addLog('Group created: ${group.name}.');
      return null;
    } catch (error) {
      _addLog('Group create failed: $error');
      return _readableError(error);
    } finally {
      if (mounted) {
        setState(() => _groupsBusy = false);
      }
    }
  }

  Future<void> _openGroup(GroupSummary group) async {
    if (_openingConversation) return;
    final session = _session;
    if (session == null) {
      _addLog('Sign in before opening a group.');
      return;
    }

    FocusScope.of(context).unfocus();
    final conversationKey = 'group:${group.id}';
    setState(() => _openingConversation = true);
    try {
      final history = await loadMessageHistory(conversationKey);
      final groupKeyBase64 = await loadOrFetchGroupKey(
        signalingUri: Uri.parse(_signalingController.text.trim()),
        session: session,
        group: group,
      );
      await _client.disconnect();
      if (!mounted || _session != session) return;
      setState(() {
        _groupChatActive = true;
        _activeTitle = group.name;
        _activeSubtitle = '${group.members.length} members';
        _drafts.open(conversationKey, _messageController);
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
        memberCount: group.members.length,
      );
    } catch (error) {
      if (mounted) setState(() => _status = PeerStatus.failed);
      _addLog('Open group failed: $error');
      _showError(error);
    } finally {
      if (mounted) setState(() => _openingConversation = false);
    }
  }

  void _toggleCamera() {
    if (_groupChatActive) {
      unawaited(_groupClient.setCameraEnabled(!_groupClient.cameraEnabled));
      return;
    }
    unawaited(_client.setCameraEnabled(!_client.cameraEnabled));
  }

  void _openChatListEntry(ChatListEntry entry) {
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

  void _toggleScreenSharePause() {
    if (_groupChatActive) {
      unawaited(
        _groupClient.setScreenSharePaused(!_groupClient.screenSharePaused),
      );
    } else {
      unawaited(_client.setScreenSharePaused(!_client.screenSharePaused));
    }
  }

  void _changeScreenSource() {
    unawaited(
      _groupChatActive
          ? _groupClient.setScreenShareEnabled(true)
          : _client.setScreenShareEnabled(true),
    );
  }

  void _startCall() {
    setState(() => _showCallSummary = false);
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
    setState(() {});
  }

  void _onCallMediaChanged({required bool group}) {
    if (!mounted) return;
    if (group == _groupChatActive && _hasOpenConversation) {
      final state = group ? _groupClient.callState : _client.callState;
      if (!group && state == CallState.outgoing) {
        _outgoingCallTimeout ??= Timer(const Duration(seconds: 60), () {
          if (mounted &&
              !_groupChatActive &&
              _client.callState == CallState.outgoing) {
            _endCall(outcome: 'No answer');
          }
        });
      } else {
        _outgoingCallTimeout?.cancel();
        _outgoingCallTimeout = null;
      }
      final previous = _callSession.summary;
      _callSession.update(state, title: _activeTitle, group: group);
      final summary = _callSession.summary;
      if (summary != null && !identical(summary, previous)) {
        _showCallSummary = true;
        _callHistory.insert(
          0,
          CallHistoryEntry(
            title: summary.title,
            subtitle:
                '${summary.outcome}${summary.connected ? ' · ${formatCallDuration(summary.duration)}' : ''}',
            startedAt: summary.startedAt,
            outgoing: summary.outgoing,
          ),
        );
      }
    }
    setState(() {});
  }

  void _acceptCall() {
    unawaited(_client.acceptCall());
  }

  void _declineCall() {
    _callSession.endOutcome = 'Call declined';
    _client.declineCall();
  }

  void _endCall({String? outcome}) {
    final state = _groupChatActive ? _groupClient.callState : _client.callState;
    _callSession.endOutcome =
        outcome ??
        (state == CallState.active
            ? (_groupChatActive ? 'You left the call' : 'Call ended')
            : 'Call canceled');
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

    final queued = !_groupChatActive && !_client.canMessage;
    if (_groupChatActive) {
      _groupClient.send(text);
    } else {
      _client.send(text);
    }
    _messageController.clear();
    if (queued) {
      showPeepFeedback(
        context,
        'Message queued until this conversation reconnects.',
      );
    }
  }

  Future<void> _sendAttachment() async {
    if (_attachmentBusy) return;
    setState(() => _attachmentBusy = true);
    try {
      if (_groupChatActive) {
        await _groupClient.pickAndSendAttachment();
      } else {
        await _client.pickAndSendAttachment();
      }
    } catch (error) {
      _addLog('Attachment failed: $error');
      _showError(error);
    } finally {
      if (mounted) setState(() => _attachmentBusy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_readableError(error))));
  }

  void _addLog(String message) {
    if (!mounted) return;
    if (message == 'Call declined.') {
      _callSession.endOutcome = 'Call declined';
    } else if (message.startsWith('Could not start microphone:') ||
        message.startsWith('Could not start group call:')) {
      _callSession.endOutcome = 'Call could not start';
    }
    setState(() {
      _logs
        ..add(message)
        ..removeRange(0, _logs.length > 80 ? _logs.length - 80 : 0);
    });
    final mediaFailure = switch (message) {
      _ when message.startsWith('Could not start microphone:') =>
        'Microphone unavailable. Check permissions or try another input device.',
      _ when message.startsWith('Could not start camera:') =>
        'Camera unavailable. Check permissions or try another camera.',
      _ when message.startsWith('Could not share screen:') =>
        'Screen sharing did not start. Try again and choose a screen.',
      _ when message.startsWith('Could not update screen sharing:') =>
        'Could not change screen sharing. Please try again.',
      _ when message.startsWith('Could not start group call:') =>
        'The group call could not start. Check your connection and media permissions, then try again.',
      _ => null,
    };
    if (mediaFailure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(mediaFailure)));
    }
  }

  void _saveActiveHistory() {
    final conversationKey = _activeConversationKey;
    if (conversationKey == null) {
      return;
    }

    unawaited(saveMessageHistory(conversationKey, _messages));
    final session = _session;
    if (session != null) {
      unawaited(_refreshRecentConversations(session.username));
    }
  }

  Future<void> _refreshRecentConversations(String username) async {
    final session = _session;
    if (session == null || session.username != username) return;
    try {
      final conversations = await listStoredDirectConversations(username);
      if (!mounted || _session != session) return;
      setState(() {
        _recentConversations
          ..clear()
          ..addAll(conversations);
      });
    } catch (error) {
      if (mounted && _session == session) {
        _addLog('Could not load recent conversations: $error');
      }
    }
  }

  List<ChatListEntry> _chatListEntries() {
    final entriesByContact = <String, ChatListEntry>{};
    for (final conversation in _recentConversations) {
      entriesByContact[conversation.contactUsername] = ChatListEntry(
        contactUsername: conversation.contactUsername,
        lastText: conversation.lastText,
        updatedAt: conversation.updatedAt,
        unreadCount: 0,
      );
    }

    for (final summary in _mailboxSummaries) {
      final existing = entriesByContact[summary.contactUsername];
      entriesByContact[summary.contactUsername] = ChatListEntry(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final colorScheme = Theme.of(context).colorScheme;
            final wide = constraints.maxWidth >= 860;
            if (!_hasOpenConversation) {
              if (_session == null) {
                return SingleChildScrollView(
                  padding: EdgeInsets.all(wide ? 32 : 16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: AccountScreen(
                        signalingController: _signalingController,
                        emailController: _emailController,
                        usernameController: _usernameController,
                        passwordController: _passwordController,
                        busy: _authBusy,
                        onCreateAccount: _createAccount,
                        onSignIn: _signIn,
                        error: _authError,
                      ),
                    ),
                  ),
                );
              }

              return MessengerHome(
                signalingController: _signalingController,
                contactController: _contactController,
                groupNameController: _groupNameController,
                groupMembersController: _groupMembersController,
                session: _session!,
                chatEntries: _chatListEntries(),
                groups: _groups,
                callHistory: _callHistory,
                connecting:
                    _openingConversation ||
                    _status == PeerStatus.signaling ||
                    _status == PeerStatus.waitingForPeer ||
                    _status == PeerStatus.connecting,
                groupsBusy: _groupsBusy || _openingConversation,
                onConnect: _connect,
                onOpenChatEntry: _openChatListEntry,
                onCreateGroup: _createGroup,
                onOpenGroup: _openGroup,
                onRefreshGroups: _refreshHomeData,
                onSignOut: _signOut,
                logs: _logs,
                onMediaSettings: _showMediaSettings,
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
            if (activeCallState != CallState.idle) {
              return CallScreen(
                isGroup: _groupChatActive,
                startedAt: _callSession.startedAt,
                connectedAt: _callSession.connectedAt,
                title: _activeTitle,
                subtitle: _activeSubtitle,
                callState: activeCallState,
                connected: _isConnected,
                cameraEnabled: activeCameraEnabled,
                microphoneEnabled: activeMicrophoneEnabled,
                screenShareEnabled: activeScreenShareEnabled,
                screenSharePaused: _groupChatActive
                    ? _groupClient.screenSharePaused
                    : _client.screenSharePaused,
                screenFrameRate: _mediaSettings.screenFrameRate,
                screenBitrateKbps: _mediaSettings.screenBitrateKbps,
                localVideoViewType: _groupChatActive
                    ? _groupClient.localVideoViewType
                    : _client.localVideoViewType,
                remoteVideoViews: _groupChatActive
                    ? _groupClient.remoteVideoViews
                    : [
                        MediaView(
                          title: _activeTitle,
                          viewType: _client.remoteVideoViewType,
                        ),
                      ],
                onAccept: _acceptCall,
                onDecline: _declineCall,
                onEnd: _endCall,
                onToggleCamera: _toggleCamera,
                onToggleMicrophone: _toggleMicrophone,
                onToggleScreenShare: _toggleScreenShare,
                onToggleScreenSharePause: _toggleScreenSharePause,
                onChangeScreenSource: _changeScreenSource,
                onScreenSettings: () => _showMediaSettings(screenOnly: true),
                onMediaSettings: _showMediaSettings,
              );
            }
            if (_showCallSummary && _callSession.summary != null) {
              return CallEndedScreen(
                summary: _callSession.summary!,
                onDone: () => setState(() => _showCallSummary = false),
                onCallAgain:
                    (_groupChatActive ? _groupClient.canSend : _client.canSend)
                    ? _startCall
                    : null,
              );
            }
            final chatHeader = ConversationHeader(
              room: _activeTitle,
              peer: _activeSubtitle,
              statusLabel: _statusLabel(),
              statusColor: _statusColor(colorScheme),
              encryptionReady: _groupChatActive || _client.encryptionReady,
              canReconnect: _canReconnect,
              canCall: _groupChatActive
                  ? _groupClient.canSend
                  : _client.canSend,
              onBack: _disconnect,
              onReconnect: _reconnectActiveConversation,
              onStartCall: _startCall,
              onMediaSettings: _showMediaSettings,
            );
            final chat = ConversationPanel(
              key: ValueKey(_activeConversationKey),
              messages: _messages,
              scrollController: _scrollController,
              messageController: _messageController,
              canType: _groupChatActive
                  ? _groupClient.canSend
                  : _hasOpenConversation,
              canSend: _groupChatActive
                  ? _groupClient.canSend
                  : _client.canMessage,
              canAttach: _groupChatActive
                  ? _groupClient.canSend
                  : _client.canMessage,
              onSend: _sendMessage,
              onAttach: _sendAttachment,
              attachmentBusy: _attachmentBusy,
            );

            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && !_openingConversation) unawaited(_disconnect());
              },
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Padding(
                    padding: EdgeInsets.all(wide ? 24 : 0),
                    child: Column(
                      children: [
                        chatHeader,
                        Expanded(child: chat),
                      ],
                    ),
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
      PeerStatus.signaling => 'Connecting',
      PeerStatus.waitingForPeer => 'Waiting for peer',
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

String _defaultSignalingUrl() {
  const configured = String.fromEnvironment('PEEP_SIGNALING_URL');
  if (configured.isNotEmpty) return configured;
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'ws://10.0.2.2:8787/ws'
      : 'ws://127.0.0.1:8787/ws';
}
