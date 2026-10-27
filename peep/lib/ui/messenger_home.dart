import 'package:flutter/material.dart';

import '../peer.dart';
import 'peep_theme.dart';

/// View model for one direct-conversation row in the unified inbox.
class ChatListEntry {
  const ChatListEntry({
    required this.contactUsername,
    required this.lastText,
    required this.updatedAt,
    required this.unreadCount,
    this.displayTime,
  });

  final String contactUsername;
  final String lastText;
  final DateTime updatedAt;
  final int unreadCount;
  final String? displayTime;
}

/// A lightweight local record for the Calls tab. Call transport remains owned
/// by the application controller.
class CallHistoryEntry {
  const CallHistoryEntry({
    required this.title,
    required this.subtitle,
    required this.startedAt,
    required this.outgoing,
  });

  final String title;
  final String subtitle;
  final DateTime startedAt;
  final bool outgoing;
}

class MessengerHome extends StatefulWidget {
  const MessengerHome({
    super.key,
    required this.signalingController,
    required this.contactController,
    required this.groupNameController,
    required this.groupMembersController,
    required this.session,
    required this.chatEntries,
    required this.groups,
    required this.callHistory,
    required this.connecting,
    required this.groupsBusy,
    required this.onConnect,
    required this.onOpenChatEntry,
    required this.onCreateGroup,
    required this.onOpenGroup,
    required this.onRefreshGroups,
    required this.onSignOut,
    required this.logs,
    required this.onMediaSettings,
  });

  final TextEditingController signalingController;
  final TextEditingController contactController;
  final TextEditingController groupNameController;
  final TextEditingController groupMembersController;
  final AuthSession session;
  final List<ChatListEntry> chatEntries;
  final List<GroupSummary> groups;
  final List<CallHistoryEntry> callHistory;
  final bool connecting;
  final bool groupsBusy;
  final VoidCallback onConnect;
  final ValueChanged<ChatListEntry> onOpenChatEntry;
  final ValueChanged<GroupSummary> onOpenGroup;
  final Future<String?> Function() onCreateGroup;
  final Future<void> Function() onRefreshGroups;
  final VoidCallback onSignOut;
  final List<String> logs;
  final VoidCallback onMediaSettings;

  @override
  State<MessengerHome> createState() => _MessengerHomeState();
}

class _MessengerHomeState extends State<MessengerHome> {
  static const _primary = PeepColors.primary;
  static const _ink = PeepColors.ink;
  static const _muted = PeepColors.muted;
  static const _border = PeepColors.border;
  final _searchController = TextEditingController();
  int _tabIndex = 0;
  String _searchQuery = '';
  bool _unreadOnly = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showNewChat() {
    showDialog<void>(
      context: context,
      builder: (_) => _NewMessageDialog(
        controller: widget.contactController,
        username: widget.session.username,
        busy: widget.connecting,
        onConnect: widget.onConnect,
      ),
    );
  }

  void _showNewGroup() {
    showDialog<void>(
      context: context,
      builder: (context) => _NewGroupDialog(
        groupNameController: widget.groupNameController,
        groupMembersController: widget.groupMembersController,
        onCreate: widget.onCreateGroup,
      ),
    );
  }

  void _showConnectionSettings() {
    showDialog<void>(
      context: context,
      builder: (_) =>
          _ConnectionSettingsDialog(controller: widget.signalingController),
    );
  }

  void _showComposeSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_add_alt_1),
                  ),
                  title: const Text('New message'),
                  subtitle: const Text('Start a private conversation'),
                  onTap: widget.connecting
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          Future<void>.delayed(Duration.zero, _showNewChat);
                        },
                ),
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.group_add)),
                  title: const Text('New group'),
                  subtitle: const Text('Create an encrypted group'),
                  onTap: widget.groupsBusy
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          Future<void>.delayed(Duration.zero, _showNewGroup);
                        },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _matchesSearch(String title, String subtitle) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return title.toLowerCase().contains(query) ||
        subtitle.toLowerCase().contains(query);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  Widget _inbox() {
    final sourceEntries = widget.chatEntries;
    final sourceGroups = widget.groups;
    final entries = sourceEntries
        .where(
          (entry) =>
              (!_unreadOnly || entry.unreadCount > 0) &&
              _matchesSearch(entry.contactUsername, entry.lastText),
        )
        .toList(growable: false);
    final groups = _unreadOnly
        ? const <GroupSummary>[]
        : sourceGroups
              .where(
                (group) => _matchesSearch(
                  group.name,
                  '${group.members.length} members encrypted group',
                ),
              )
              .toList(growable: false);
    final empty = entries.isEmpty && groups.isEmpty;
    final hasSourceContent =
        sourceEntries.isNotEmpty || sourceGroups.isNotEmpty;

    final rows = <Widget>[
      if (entries.isNotEmpty) _sectionLabel('DIRECT MESSAGES', entries.length),
      for (final entry in entries)
        _ConversationTile.direct(
          entry: entry,
          enabled: !widget.connecting,
          onTap: () => widget.onOpenChatEntry(entry),
        ),
      if (groups.isNotEmpty) _sectionLabel('YOUR GROUPS', groups.length),
      for (final group in groups)
        _ConversationTile.group(
          group: group,
          enabled: !widget.groupsBusy,
          onTap: () => widget.onOpenGroup(group),
        ),
    ];
    return RefreshIndicator(
      onRefresh: widget.onRefreshGroups,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
              child: Column(
                children: [
                  if (widget.connecting)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search or start a conversation',
                      hintStyle: const TextStyle(fontSize: 13, color: _muted),
                      prefixIcon: const Icon(Icons.search_rounded, size: 21),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: _clearSearch,
                              icon: const Icon(Icons.close_rounded),
                            ),
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _FilterPill(
                              label: 'All',
                              selected: !_unreadOnly,
                              onTap: () => setState(() => _unreadOnly = false),
                            ),
                            _FilterPill(
                              label: 'Unread',
                              selected: _unreadOnly,
                              onTap: () => setState(() => _unreadOnly = true),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh conversations',
                        onPressed: widget.groupsBusy
                            ? null
                            : widget.onRefreshGroups,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 20,
                          color: _muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (empty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessengerEmpty(
                icon: hasSourceContent
                    ? Icons.search_off_rounded
                    : Icons.forum_outlined,
                title: hasSourceContent
                    ? 'No conversations found'
                    : 'No messages yet',
                message: hasSourceContent
                    ? 'Try another search or switch back to all conversations.'
                    : 'Your next good conversation starts with a hello.',
                actionLabel: hasSourceContent ? null : 'Start a conversation',
                onAction: hasSourceContent ? null : _showNewChat,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (_, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: rows[index],
                ),
              ),
            ),
          if (widget.groupsBusy)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 14),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            color: _muted,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: const TextStyle(fontSize: 11, color: PeepColors.subtle),
        ),
      ],
    ),
  );

  Widget _calls() {
    if (widget.callHistory.isEmpty) {
      return const _MessengerEmpty(
        icon: Icons.call_outlined,
        title: 'No calls yet',
        message: 'Calls you make or receive will appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: widget.callHistory.length,
      separatorBuilder: (_, _) => const Divider(indent: 72),
      itemBuilder: (context, index) {
        final call = widget.callHistory[index];
        return ListTile(
          leading: _Avatar(label: call.title),
          title: Text(
            call.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${call.subtitle} • ${_compactTime(call.startedAt)}'),
          trailing: Icon(
            call.outgoing
                ? Icons.call_made_rounded
                : Icons.call_received_rounded,
            color: _primary,
          ),
        );
      },
    );
  }

  void _showSettingsInfo(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => _MessengerDialog(
        title: title,
        actionLabel: 'Done',
        onAction: () => Navigator.of(context).pop(),
        child: Text(message),
      ),
    );
  }

  Widget _settings() => ListView(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
    children: [
      Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
        ),
        child: ListTile(
          leading: _Avatar(label: widget.session.username),
          title: Text(
            '@${widget.session.username}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text(widget.session.email, overflow: TextOverflow.ellipsis),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          'PREFERENCES',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            color: PeepColors.muted,
          ),
        ),
      ),
      _SettingsTile(
        icon: Icons.person_outline,
        title: 'Account',
        onTap: () => _showSettingsInfo(
          'Account',
          '@${widget.session.username}\n${widget.session.email}',
        ),
      ),
      _SettingsTile(
        icon: Icons.lock_outline,
        title: 'Privacy',
        onTap: () => _showSettingsInfo(
          'Privacy',
          'Messages, attachments, and group conversations are end-to-end encrypted.',
        ),
      ),
      _SettingsTile(
        icon: Icons.tune_rounded,
        title: 'Call & media quality',
        onTap: widget.onMediaSettings,
      ),
      _SettingsTile(
        icon: Icons.hub_outlined,
        title: 'Connection settings',
        onTap: _showConnectionSettings,
      ),
      _SettingsTile(
        icon: Icons.terminal_rounded,
        title: 'Connection activity',
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => _MessengerDialog(
            title: 'Connection activity',
            actionLabel: 'Done',
            onAction: () => Navigator.of(context).pop(),
            child: SizedBox(
              width: 400,
              height: 220,
              child: ListView(
                children: widget.logs.reversed
                    .map(
                      (log) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(log, style: const TextStyle(fontSize: 12)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ),
      ),
      const Divider(),
      _SettingsTile(
        icon: Icons.logout_rounded,
        title: 'Sign out',
        destructive: true,
        onTap: widget.connecting ? null : widget.onSignOut,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      const titles = ['Chats', 'Calls', 'Settings'];
      const subtitles = [
        'A little closer to your people.',
        'Make time for a real conversation.',
        'Make yourself at home.',
      ];
      final body = switch (_tabIndex) {
        0 => _inbox(),
        1 => _calls(),
        _ => _settings(),
      };
      final content = Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, wide ? 32 : 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!wide) ...[
                  Row(
                    children: [
                      const PeepBrand(),
                      const Spacer(),
                      PeepAvatar(label: widget.session.username, radius: 18),
                    ],
                  ),
                  const SizedBox(height: 26),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titles[_tabIndex],
                            style: Theme.of(context).textTheme.headlineLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subtitles[_tabIndex],
                            style: const TextStyle(fontSize: 13, color: _muted),
                          ),
                        ],
                      ),
                    ),
                    if (_tabIndex == 0)
                      IconButton.filled(
                        tooltip: 'New message',
                        onPressed: widget.connecting ? null : _showNewChat,
                        style: IconButton.styleFrom(backgroundColor: _primary),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'More options',
                      onPressed: _showComposeSheet,
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: body),
          if (_tabIndex == 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 16, top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 13, color: _muted),
                  SizedBox(width: 6),
                  Text(
                    'End-to-end encrypted',
                    style: TextStyle(fontSize: 11, color: _muted),
                  ),
                ],
              ),
            ),
        ],
      );
      return Material(
        color: PeepColors.canvas,
        child: Row(
          children: [
            if (wide) _sidebar(),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 960),
                        child: content,
                      ),
                    ),
                  ),
                  if (!wide)
                    NavigationBar(
                      selectedIndex: _tabIndex,
                      onDestinationSelected: (index) =>
                          setState(() => _tabIndex = index),
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.chat_bubble_outline_rounded),
                          selectedIcon: Icon(Icons.chat_bubble_rounded),
                          label: 'Chats',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.call_outlined),
                          selectedIcon: Icon(Icons.call_rounded),
                          label: 'Calls',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings_rounded),
                          label: 'Settings',
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _sidebar() => Container(
    width: 246,
    color: PeepColors.navy,
    padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 12),
          child: PeepBrand(light: true),
        ),
        const SizedBox(height: 44),
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 14),
          child: Text(
            'YOUR SPACE',
            style: TextStyle(
              color: Color(0xff86a4a8),
              fontSize: 10,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (var index = 0; index < 3; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: _tabIndex == index
                  ? const Color(0xff2b484e)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _tabIndex = index),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        [
                          Icons.forum_outlined,
                          Icons.call_outlined,
                          Icons.settings_outlined,
                        ][index],
                        color: _tabIndex == index
                            ? PeepColors.mint
                            : const Color(0xffa9bec1),
                        size: 21,
                      ),
                      const SizedBox(width: 14),
                      Text(
                        ['Chats', 'Calls', 'Settings'][index],
                        style: TextStyle(
                          color: _tabIndex == index
                              ? Colors.white
                              : const Color(0xffa9bec1),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (index == 0 &&
                          widget.chatEntries.any((e) => e.unreadCount > 0)) ...[
                        const Spacer(),
                        const Icon(
                          Icons.circle,
                          size: 7,
                          color: PeepColors.mint,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xff355159)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.waving_hand_outlined,
                color: PeepColors.mint,
                size: 26,
              ),
              SizedBox(height: 14),
              Text(
                'Good to have you here.',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'A quiet corner of the internet, for you and your people.',
                style: TextStyle(
                  color: Color(0xffa9bec1),
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            PeepAvatar(label: widget.session.username, radius: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '@${widget.session.username}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Account settings',
              onPressed: () => setState(() => _tabIndex = 2),
              icon: const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xffa9bec1),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _NewMessageDialog extends StatefulWidget {
  const _NewMessageDialog({
    required this.controller,
    required this.username,
    required this.busy,
    required this.onConnect,
  });
  final TextEditingController controller;
  final String username;
  final bool busy;
  final VoidCallback onConnect;
  @override
  State<_NewMessageDialog> createState() => _NewMessageDialogState();
}

class _NewMessageDialogState extends State<_NewMessageDialog> {
  final _form = GlobalKey<FormState>();
  void _connect() {
    if (widget.busy || !_form.currentState!.validate()) return;
    Navigator.of(context).pop();
    widget.onConnect();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New message'),
    scrollable: true,
    content: Form(
      key: _form,
      child: TextFormField(
        controller: widget.controller,
        autofocus: true,
        enabled: !widget.busy,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _connect(),
        validator: (value) {
          final username = value?.trim().toLowerCase() ?? '';
          if (!RegExp(r'^[a-z0-9_-]{3,32}$').hasMatch(username)) {
            return 'Enter a valid username (3–32 characters).';
          }
          if (username == widget.username.toLowerCase()) {
            return 'Choose someone other than yourself.';
          }
          return null;
        },
        decoration: const InputDecoration(
          labelText: 'Username',
          hintText: 'e.g. alex',
          prefixIcon: Icon(Icons.alternate_email_rounded),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: widget.busy ? null : _connect,
        child: Text(widget.busy ? 'Connecting…' : 'Next'),
      ),
    ],
  );
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({
    required this.groupNameController,
    required this.groupMembersController,
    required this.onCreate,
  });

  final TextEditingController groupNameController;
  final TextEditingController groupMembersController;
  final Future<String?> Function() onCreate;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  bool _creating = false;
  String? _error;

  Future<void> _create() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onCreate();
    } catch (_) {
      error = 'Could not create the group. Please try again.';
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _creating = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New group'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.groupNameController,
          autofocus: true,
          enabled: !_creating,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.groupMembersController,
          minLines: 2,
          maxLines: 3,
          enabled: !_creating,
          decoration: const InputDecoration(
            labelText: 'Member usernames',
            hintText: 'alex, maya, sam',
            helperText: 'Separate usernames with commas',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: _creating ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _creating ? null : _create,
        child: Text(_creating ? 'Creating…' : 'Create'),
      ),
    ],
  );
}

class _ConnectionSettingsDialog extends StatefulWidget {
  const _ConnectionSettingsDialog({required this.controller});
  final TextEditingController controller;

  @override
  State<_ConnectionSettingsDialog> createState() =>
      _ConnectionSettingsDialogState();
}

class _ConnectionSettingsDialogState extends State<_ConnectionSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _draft = TextEditingController(text: widget.controller.text);

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    widget.controller.text = _draft.text.trim();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _MessengerDialog(
    title: 'Connection settings',
    actionLabel: 'Done',
    onAction: _save,
    child: Form(
      key: _formKey,
      child: TextFormField(
        controller: _draft,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _save(),
        decoration: const InputDecoration(
          labelText: 'Signaling server URL',
          prefixIcon: Icon(Icons.dns_outlined),
        ),
        validator: (value) {
          final uri = Uri.tryParse(value?.trim() ?? '');
          if (uri == null ||
              !['ws', 'wss'].contains(uri.scheme) ||
              uri.host.isEmpty) {
            return 'Enter a ws:// or wss:// server address.';
          }
          return null;
        },
      ),
    ),
  );
}

class _MessengerDialog extends StatelessWidget {
  const _MessengerDialog({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    required this.child,
  });
  final String title;
  final String actionLabel;
  final VoidCallback onAction;
  final Widget child;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    scrollable: true,
    content: child,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: onAction, child: Text(actionLabel)),
    ],
  );
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? _MessengerHomeState._primary : Colors.white,
    shape: StadiumBorder(
      side: BorderSide(
        color: selected
            ? _MessengerHomeState._primary
            : _MessengerHomeState._border,
      ),
    ),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64, minHeight: 40),
        child: Center(
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : _MessengerHomeState._ink,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile.direct({
    required this.entry,
    required this.enabled,
    required this.onTap,
  }) : group = null;
  const _ConversationTile.group({
    required this.group,
    required this.enabled,
    required this.onTap,
  }) : entry = null;
  final ChatListEntry? entry;
  final GroupSummary? group;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final direct = entry != null;
    final title = direct ? entry!.contactUsername : group!.name;
    final subtitle = direct
        ? entry!.lastText
        : '${group!.members.length} members • Encrypted group';
    final unread = direct ? entry!.unreadCount : 0;
    return Material(
      color: unread > 0 ? Colors.white : Colors.white.withValues(alpha: .65),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          child: Row(
            children: [
              _Avatar(label: title, group: !direct),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _MessengerHomeState._ink,
                        fontSize: 15,
                        fontWeight: unread > 0
                            ? FontWeight.w800
                            : FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _MessengerHomeState._muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      direct
                          ? entry!.displayTime ?? _compactTime(entry!.updatedAt)
                          : '',
                      style: const TextStyle(
                        color: _MessengerHomeState._muted,
                        fontSize: 11,
                      ),
                    ),
                    if (unread > 0) ...[
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        height: 22,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: _MessengerHomeState._primary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, this.group = false});
  final String label;
  final bool group;
  @override
  Widget build(BuildContext context) => PeepAvatar(label: label, group: group);
}

class _MessengerEmpty extends StatelessWidget {
  const _MessengerEmpty({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xffeaf1ff),
            foregroundColor: _MessengerHomeState._primary,
            child: Icon(icon, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _MessengerHomeState._muted),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    ),
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.onTap,
    this.destructive = false,
  });
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool destructive;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: destructive ? Colors.red : null),
    title: Text(
      title,
      style: TextStyle(color: destructive ? Colors.red : null),
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

String _compactTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(time.year, time.month, time.day);
  final days = today.difference(date).inDays;
  if (days <= 0) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return 'Yesterday';
  if (days < 7) {
    return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][time.weekday - 1];
  }
  return '${time.day}/${time.month}';
}
