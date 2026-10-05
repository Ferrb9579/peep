import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/ui/messenger_home.dart';
import 'package:peep/webrtc_peer_stub.dart'
    if (dart.library.io) 'package:peep/webrtc_peer_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TextEditingController signalingController;
  late TextEditingController contactController;
  late TextEditingController groupNameController;
  late TextEditingController groupMembersController;

  setUp(() {
    signalingController = TextEditingController(text: 'ws://10.0.2.2:8787/ws');
    contactController = TextEditingController();
    groupNameController = TextEditingController();
    groupMembersController = TextEditingController();
  });

  tearDown(() {
    signalingController.dispose();
    contactController.dispose();
    groupNameController.dispose();
    groupMembersController.dispose();
  });

  Widget buildHome({
    List<ChatListEntry> entries = const [],
    List<GroupSummary> groups = const [],
    Future<String?> Function()? onCreateGroup,
  }) => MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff4f46e5)),
    ),
    home: Scaffold(
      body: MessengerHome(
        signalingController: signalingController,
        contactController: contactController,
        groupNameController: groupNameController,
        groupMembersController: groupMembersController,
        session: const AuthSession(
          token: 'test-token',
          username: 'audit_direct',
          email: 'audit-direct@example.com',
        ),
        chatEntries: entries,
        groups: groups,
        callHistory: const [],
        connecting: false,
        groupsBusy: false,
        onConnect: () {},
        onOpenChatEntry: (_) {},
        onCreateGroup: onCreateGroup ?? () async => null,
        onOpenGroup: (_) {},
        onRefreshGroups: () async {},
        onSignOut: () {},
        logs: const [],
      ),
    ),
  );

  testWidgets('search, unread filter, and navigation remain functional', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildHome(
        entries: [
          ChatListEntry(
            contactUsername: 'Maya',
            lastText: 'Can you send over the report?',
            updatedAt: DateTime(2026, 7, 30, 12, 6),
            unreadCount: 2,
          ),
          ChatListEntry(
            contactUsername: 'Sam',
            lastText: 'Sounds good, let’s do it.',
            updatedAt: DateTime(2026, 7, 30, 9, 18),
            unreadCount: 0,
          ),
        ],
        groups: const [
          GroupSummary(
            id: 'project-atlas',
            name: 'Project Atlas',
            members: ['Maya', 'Sam'],
          ),
        ],
      ),
    );

    expect(find.text('Search or start a conversation'), findsOneWidget);
    expect(find.text('End-to-end encrypted'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Project Atlas'), findsOneWidget);

    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Sam'), findsNothing);
    expect(find.text('Project Atlas'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.enterText(find.byType(TextField).first, 'sounds good');
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsNothing);
    expect(find.text('Sam'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Project Atlas'), findsOneWidget);

    await tester.tap(find.text('Calls').last);
    await tester.pumpAndSettle();
    expect(find.text('No calls yet'), findsOneWidget);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('@audit_direct'), findsOneWidget);
    expect(find.text('audit-direct@example.com'), findsOneWidget);
  });

  testWidgets('empty inbox CTA opens the real new-message flow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildHome());

    expect(find.text('No messages yet'), findsOneWidget);
    await tester.tap(find.text('Start a conversation'));
    await tester.pumpAndSettle();

    expect(find.text('New message'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets(
    'group creation keeps backend errors visible and awaits success',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var attempts = 0;
      await tester.pumpWidget(
        buildHome(
          onCreateGroup: () async {
            attempts++;
            return attempts == 1
                ? 'Member username does not exist: nobody'
                : null;
          },
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Group name'),
        'Backend Team',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Member usernames'),
        'nobody',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(
        find.text('Member username does not exist: nobody'),
        findsOneWidget,
      );
      expect(find.text('New group'), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('New group'), findsNothing);
    },
  );
}
