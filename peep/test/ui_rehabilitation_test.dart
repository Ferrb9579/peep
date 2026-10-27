import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/peer.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/ui/account_screen.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/conversation_screen.dart';
import 'package:peep/ui/media_settings_sheet.dart';
import 'package:peep/ui/peep_theme.dart';

void main() {
  testWidgets('account validates before authentication and reveals password', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controllers = List.generate(4, (_) => TextEditingController());
    controllers[0].text = 'ws://localhost:8787/ws';
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    var submissions = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountScreen(
              signalingController: controllers[0],
              emailController: controllers[1],
              usernameController: controllers[2],
              passwordController: controllers[3],
              busy: false,
              onCreateAccount: () => submissions++,
              onSignIn: () => submissions++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sign in securely'));
    await tester.pumpAndSettle();
    expect(submissions, 0);
    expect(find.text('Enter your password.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      'alice',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'secret123',
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tester.ensureVisible(find.text('Sign in securely'));
    await tester.tap(find.text('Sign in securely'));
    expect(submissions, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('group call exposes every participant at narrow widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var settingsOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: CallScreen(
          title: 'The weekend crew',
          subtitle: '3 members',
          callState: CallState.active,
          connected: true,
          cameraEnabled: false,
          microphoneEnabled: true,
          screenShareEnabled: false,
          localVideoViewType: null,
          remoteVideoViews: const [
            MediaView(title: 'Alice', viewType: null),
            MediaView(title: 'Bob', viewType: null),
          ],
          onAccept: () {},
          onDecline: () {},
          onEnd: () {},
          onToggleCamera: () {},
          onToggleMicrophone: () {},
          onToggleScreenShare: () {},
          onMediaSettings: () => settingsOpened = true,
        ),
      ),
    );
    expect(find.text('Alice'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Bob'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Bob'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('You'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('You'), findsOneWidget);
    await tester.tap(find.byTooltip('Call & media quality'));
    expect(settingsOpened, true);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'empty composer cannot send and messages do not imply read receipts',
    (tester) async {
      final input = TextEditingController();
      final scroll = ScrollController();
      addTearDown(input.dispose);
      addTearDown(scroll.dispose);
      var sent = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: Scaffold(
            body: ConversationPanel(
              messages: [
                ChatMessage(
                  text: 'Hello',
                  isLocal: true,
                  sentAt: DateTime.now(),
                ),
              ],
              scrollController: scroll,
              messageController: input,
              canType: true,
              canSend: true,
              canAttach: false,
              onSend: () => sent++,
              onAttach: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Send'));
      expect(sent, 0);
      await tester.enterText(find.byType(TextField), 'Hi there');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      expect(sent, 1);
      expect(find.byIcon(Icons.done_all_rounded), findsNothing);
      expect(find.text('Today'), findsOneWidget);
    },
  );
  testWidgets('quality presets change saved values and failed saves recover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MediaSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: Scaffold(
          body: MediaSettingsSheet(
            settings: MediaSettings.defaults,
            loadCodecs: () async => const MediaCodecSupport(
              video: ['video/vp8', 'video/h264'],
              audio: ['audio/opus'],
            ),
            onSave: (settings) async {
              saved = settings;
              return 'Device rejected live limits';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Data saver'));
    await tester.pumpAndSettle();
    expect(find.text('360p'), findsOneWidget);
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(saved!.videoBitrateKbps, 400);
    expect(saved!.frameRate, 15);
    expect(saved!.audioBitrateKbps, 32);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1500),
    );
    await tester.pumpAndSettle();
    expect(find.text('Device rejected live limits'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
