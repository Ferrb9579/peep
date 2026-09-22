import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/ui/messenger_home.dart';
import 'package:peep/ui/peep_theme.dart';
import 'package:peep/webrtc_peer_stub.dart'
    if (dart.library.io) 'package:peep/webrtc_peer_native.dart'
    if (dart.library.html) 'package:peep/webrtc_peer_web.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool empty = false,
    ValueChanged<ChatListEntry>? onOpenChat,
    ValueChanged<GroupSummary>? onOpenGroup,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controllers = List.generate(4, (_) => TextEditingController());
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    await tester.pumpWidget(MaterialApp(
      theme: PeepTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: MessengerHome(
          signalingController: controllers[0],
          contactController: controllers[1],
          groupNameController: controllers[2],
          groupMembersController: controllers[3],
          session: const AuthSession(
            token: 'test',
            username: 'river',
            email: 'river@example.com',
          ),
          chatEntries: empty ? [] : [
            ChatListEntry(
              contactUsername: 'Alex',
              lastText: 'See you tomorrow',
              updatedAt: DateTime.now(),
              unreadCount: 120,
            ),
            ChatListEntry(
              contactUsername: 'Maya',
              lastText: 'The photos look great',
              updatedAt: DateTime.now().subtract(const Duration(days: 1)),
              unreadCount: 0,
            ),
          ],
          groups: empty ? [] : const [
            GroupSummary(id: 'friends', name: 'Weekend plans',
                members: ['river', 'alex']),
          ],
          callHistory: const [],
          connecting: false,
          groupsBusy: false,
          onConnect: () {},
          onOpenChatEntry: onOpenChat ?? (_) {},
          onCreateGroup: () {},
          onOpenGroup: onOpenGroup ?? (_) {},
          onRefreshGroups: () {},
          onSignOut: () {},
          logs: const [],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('search and filters preserve conversation actions', (tester) async {
    String? opened;
    await mount(tester, onOpenChat: (entry) => opened = entry.contactUsername);
    expect(find.text('99+'), findsOneWidget);
    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsNothing);
    expect(find.text('Weekend plans'), findsNothing);
    await tester.tap(find.text('Alex'));
    expect(opened, 'Alex');

    await tester.tap(find.text('All'));
    await tester.enterText(find.byType(TextField), ' PHOTOS ');
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Alex'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsOneWidget);
  });

  testWidgets('group filter opens the original group', (tester) async {
    String? opened;
    await mount(tester, onOpenGroup: (group) => opened = group.id);
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsNothing);
    await tester.tap(find.text('Weekend plans'));
    expect(opened, 'friends');
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No conversations found'), findsOneWidget);
    await tester.tap(find.text('Reset filters'));
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsOneWidget);
  });

  testWidgets('navigation adapts to desktop and opens settings', (tester) async {
    await mount(tester, size: const Size(1200, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('@river'), findsOneWidget);
    await tester.tap(find.text('Connection settings'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Signaling server URL'), findsOneWidget);
  });

  testWidgets('narrow layout supports large text and empty-state compose',
      (tester) async {
    await mount(tester, size: const Size(320, 800), textScale: 1.5, empty: true);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    final compose = find.widgetWithText(FilledButton, 'Start a conversation');
    await tester.ensureVisible(compose);
    await tester.tap(compose);
    await tester.pumpAndSettle();
    expect(find.text('New message'), findsOneWidget);
    expect(find.text('New group'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
