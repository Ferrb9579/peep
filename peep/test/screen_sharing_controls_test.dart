import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/peer.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/media_settings_sheet.dart';
import 'package:peep/ui/peep_theme.dart';

void main() {
  testWidgets('exact screen values validate at one fps on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MediaSettings? saved;
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: Scaffold(
          body: MediaSettingsSheet(
            screenOnly: true,
            settings: const MediaSettings(frameRate: 7),
            loadCodecs: () async => const MediaCodecSupport(),
            onSave: (settings) async {
              saved = settings;
              saves++;
              return 'Test save';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fps = find.widgetWithText(TextFormField, 'Screen frame rate');
    await tester.ensureVisible(fps);
    await tester.enterText(fps, '0');
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('Enter 1–60 fps.'), findsOneWidget);
    await tester.ensureVisible(fps);
    await tester.enterText(fps, '61');
    await tester.pumpAndSettle();
    expect(find.text('Enter 1–60 fps.'), findsOneWidget);
    await tester.enterText(fps, '1');
    await tester.pumpAndSettle();
    final bitrate = find.widgetWithText(
      TextFormField,
      'Screen bitrate ceiling',
    );
    await tester.ensureVisible(bitrate);
    await tester.enterText(bitrate, '777');
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(saved!.screenFrameRate, 1);
    expect(saved!.screenBitrateKbps, 777);
    expect(saved!.frameRate, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sharing controls stay reachable and reflect pause state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var paused = false;
    var changes = 0;
    var stops = 0;
    var settings = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => CallScreen(
            title: 'Bob',
            subtitle: '',
            callState: CallState.active,
            connected: true,
            cameraEnabled: false,
            microphoneEnabled: true,
            screenShareEnabled: true,
            screenSharePaused: paused,
            screenFrameRate: 1,
            screenBitrateKbps: 777,
            localVideoViewType: null,
            remoteVideoViews: const [],
            onAccept: () {},
            onDecline: () {},
            onEnd: () {},
            onToggleCamera: () {},
            onToggleMicrophone: () {},
            onToggleScreenShare: () => stops++,
            onMediaSettings: () {},
            onToggleScreenSharePause: () => setState(() => paused = !paused),
            onChangeScreenSource: () => changes++,
            onScreenSettings: () => settings++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sharing your screen · 1 fps · 777 kbps'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause sharing'));
    await tester.pumpAndSettle();
    expect(find.text('Sharing paused · no new frames'), findsOneWidget);
    await tester.tap(find.byTooltip('Resume sharing'));
    await tester.tap(find.byTooltip('Change source'));
    await tester.tap(find.text('Screen quality'));
    await tester.tap(find.byTooltip('Stop sharing'));
    expect(paused, false);
    expect(changes, 1);
    expect(settings, 1);
    expect(stops, 1);
    expect(tester.takeException(), isNull);
  });
}
