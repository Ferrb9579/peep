// Browser loopback verification using synthetic tracks, without device access.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/media/webrtc_media_web.dart';

void main() => runApp(const MaterialApp(home: Scaffold(body: _SmokeTest())));

class _SmokeTest extends StatefulWidget {
  const _SmokeTest();
  @override
  State<_SmokeTest> createState() => _SmokeTestState();
}

class _SmokeTestState extends State<_SmokeTest> {
  String _report = 'Running synthetic WebRTC loopback…';
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final left = html.RtcPeerConnection({});
    final right = html.RtcPeerConnection({});
    final leftJs = JSObject.fromInteropObject(left);
    final rightJs = JSObject.fromInteropObject(right);
    final canvas = html.CanvasElement(width: 640, height: 360);
    final context = canvas.context2D;
    context.fillStyle = '#087f73';
    context.fillRect(0, 0, 640, 360);
    final stream = JSObject.fromInteropObject(
      canvas,
    ).callMethod<JSObject>('captureStream'.toJS, 30.toJS);
    final audioConstructor = globalContext['AudioContext'] as JSFunction;
    final audio = audioConstructor.callAsConstructor<JSObject>();
    final oscillator = audio.callMethod<JSObject>('createOscillator'.toJS);
    final destination = audio.callMethod<JSObject>(
      'createMediaStreamDestination'.toJS,
    );
    oscillator.callMethod<JSAny?>('connect'.toJS, destination);
    oscillator.callMethod<JSAny?>('start'.toJS);
    final audioStream = destination['stream'] as JSObject;
    final tracks = [
      ...stream.callMethod<JSArray<JSObject>>('getTracks'.toJS).toDart,
      ...audioStream.callMethod<JSArray<JSObject>>('getTracks'.toJS).toDart,
    ];
    for (final track in tracks) {
      leftJs.callMethod<JSAny?>(
        'addTrack'.toJS,
        track,
        (track['kind'] as JSString).toDart == 'video' ? stream : audioStream,
      );
    }
    var frame = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      context.fillStyle = frame++ % 2 == 0 ? '#087f73' : '#135d88';
      context.fillRect(0, 0, 640, 360);
    });
    final logs = <String>[];
    Future<void> gather(html.RtcPeerConnection pc) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (pc.iceGatheringState != 'complete') {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('ICE gathering timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    try {
      final caps = await discoverWebMediaCodecs();
      if (caps.video.isEmpty || caps.audio.isEmpty) {
        throw StateError('No codec capabilities returned');
      }
      final preferredVideo = caps.video.contains('video/h264')
          ? 'video/h264'
          : caps.video.first;
      final preferredAudio = caps.audio.contains('audio/opus')
          ? 'audio/opus'
          : caps.audio.first;
      final settings = MediaSettings(
        videoCodec: preferredVideo,
        audioCodec: preferredAudio,
        frameRate: 24,
        videoBitrateKbps: 900,
        audioBitrateKbps: 48,
      );
      await applyWebCodecPreferences(left, settings, logs.add);
      final offer = await leftJs
          .callMethod<JSPromise<JSObject>>('createOffer'.toJS)
          .toDart;
      await leftJs
          .callMethod<JSPromise<JSAny?>>('setLocalDescription'.toJS, offer)
          .toDart;
      await gather(left);
      await rightJs
          .callMethod<JSPromise<JSAny?>>(
            'setRemoteDescription'.toJS,
            leftJs['localDescription'],
          )
          .toDart;
      final answer = await rightJs
          .callMethod<JSPromise<JSObject>>('createAnswer'.toJS)
          .toDart;
      await rightJs
          .callMethod<JSPromise<JSAny?>>('setLocalDescription'.toJS, answer)
          .toDart;
      await gather(right);
      await leftJs
          .callMethod<JSPromise<JSAny?>>(
            'setRemoteDescription'.toJS,
            rightJs['localDescription'],
          )
          .toDart;
      final connectionDeadline = DateTime.now().add(
        const Duration(seconds: 12),
      );
      while (left.connectionState != 'connected' ||
          right.connectionState != 'connected') {
        if (DateTime.now().isAfter(connectionDeadline)) {
          throw StateError('Loopback connection did not establish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await applyWebSenderLimits(left, settings);
      final sdp = (offer['sdp'] as JSString).toDart;
      String firstCodec(String kind) {
        final section = sdp.split('m=$kind ').last.split('\r\nm=').first;
        final payload = section.split('\r\n').first.trim().split(' ')[2];
        return RegExp(
              'a=rtpmap:$payload ([^/]+)',
            ).firstMatch(section)?.group(1)?.toLowerCase() ??
            '';
      }

      if (firstCodec('video') != preferredVideo.split('/').last ||
          firstCodec('audio') != preferredAudio.split('/').last) {
        throw StateError('Preferred codecs were not first in the offer');
      }
      final senderReport = <String>[];
      for (final sender
          in leftJs.callMethod<JSArray<JSObject>>('getSenders'.toJS).toDart) {
        final track = sender['track'] as JSObject;
        final kind = (track['kind'] as JSString).toDart;
        final parameters = sender.callMethod<JSObject>('getParameters'.toJS);
        final encoding =
            (parameters['encodings'] as JSArray<JSObject>).toDart.single;
        final bitrate = (encoding['maxBitrate'] as JSNumber).toDartInt;
        final expected = (kind == 'video' ? 900 : 48) * 1000;
        if (bitrate != expected) {
          throw StateError('$kind limit mismatch: $bitrate');
        }
        if (kind == 'video' &&
            (encoding['maxFramerate'] as JSNumber).toDartInt != 24) {
          throw StateError('Frame-rate limit mismatch');
        }
        senderReport.add(
          '$kind: $bitrate bps${kind == 'video' ? ' · 24 fps' : ''}',
        );
      }
      await applyWebSenderLimits(
        left,
        settings.copyWith(
          videoBitrateKbps: 1500,
          audioBitrateKbps: 96,
          frameRate: 30,
        ),
      );
      for (final sender
          in leftJs.callMethod<JSArray<JSObject>>('getSenders'.toJS).toDart) {
        final kind = ((sender['track'] as JSObject)['kind'] as JSString).toDart;
        final encoding =
            (sender.callMethod<JSObject>('getParameters'.toJS)['encodings']
                    as JSArray<JSObject>)
                .toDart
                .single;
        if ((encoding['maxBitrate'] as JSNumber).toDartInt !=
            (kind == 'video' ? 1500000 : 96000)) {
          throw StateError('Live update failed');
        }
      }
      final screenSettings = settings.copyWith(
        frameRate: 7,
        screenFrameRate: 1,
        screenBitrateKbps: 777,
        audioBitrateKbps: 55,
      );
      Future<int> encodedFrames() async {
        final stats = await leftJs
            .callMethod<JSPromise<JSObject>>('getStats'.toJS)
            .toDart;
        var frames = 0;
        stats.callMethod<JSAny?>(
          'forEach'.toJS,
          ((JSObject report, JSAny? key, JSAny? map) {
            if ((report['type'] as JSString?)?.toDart == 'outbound-rtp' &&
                (report['kind'] as JSString?)?.toDart == 'video') {
              frames += (report['framesEncoded'] as JSNumber?)?.toDartInt ?? 0;
            }
          }).toJS,
        );
        return frames;
      }

      void verifyScreenParameters(bool paused) {
        for (final sender
            in leftJs.callMethod<JSArray<JSObject>>('getSenders'.toJS).toDart) {
          final kind =
              ((sender['track'] as JSObject)['kind'] as JSString).toDart;
          final encoding =
              (sender.callMethod<JSObject>('getParameters'.toJS)['encodings']
                      as JSArray<JSObject>)
                  .toDart
                  .single;
          if ((encoding['maxBitrate'] as JSNumber).toDartInt !=
                  (kind == 'video' ? 777000 : 55000) ||
              (encoding['active'] as JSBoolean).toDart !=
                  (kind == 'audio' || !paused)) {
            throw StateError('Screen pause/bitrate parameters mismatch');
          }
          if (kind == 'video' &&
              (encoding['maxFramerate'] as JSNumber).toDartInt != 1) {
            throw StateError('1 fps screen limit was not applied');
          }
        }
      }

      await applyWebSenderLimits(left, screenSettings, screenSharing: true);
      verifyScreenParameters(false);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final beforeSlow = await encodedFrames();
      await Future<void>.delayed(const Duration(seconds: 3));
      final slowFrames = await encodedFrames() - beforeSlow;
      if (slowFrames < 1 || slowFrames > 4) {
        throw StateError('1 fps encoded $slowFrames frames over 3 seconds');
      }
      await applyWebSenderLimits(
        left,
        screenSettings,
        screenSharing: true,
        screenPaused: true,
      );
      verifyScreenParameters(true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final beforePause = await encodedFrames();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (await encodedFrames() != beforePause) {
        throw StateError('Paused screen still encodes new frames');
      }
      await applyWebSenderLimits(left, screenSettings, screenSharing: true);
      verifyScreenParameters(false);
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await encodedFrames() <= beforePause) {
        throw StateError('Resumed screen did not encode new frames');
      }
      await applyWebSenderLimits(left, screenSettings);
      for (final sender
          in leftJs.callMethod<JSArray<JSObject>>('getSenders'.toJS).toDart) {
        if (((sender['track'] as JSObject)['kind'] as JSString).toDart !=
            'video') {
          continue;
        }
        final encoding =
            (sender.callMethod<JSObject>('getParameters'.toJS)['encodings']
                    as JSArray<JSObject>)
                .toDart
                .single;
        if ((encoding['maxFramerate'] as JSNumber).toDartInt != 7 ||
            (encoding['maxBitrate'] as JSNumber).toDartInt !=
                settings.videoBitrateKbps * 1000) {
          throw StateError('Camera limits were not restored');
        }
      }
      final transceiverCount = leftJs
          .callMethod<JSArray<JSObject>>('getTransceivers'.toJS)
          .toDart
          .length;
      await detachWebVideoSenders(left);
      final replacementStream = html.MediaStream();
      final newCapture = JSObject.fromInteropObject(
        canvas,
      ).callMethod<JSObject>('captureStream'.toJS, 30.toJS);
      final replacementTrack = newCapture
          .callMethod<JSArray<JSObject>>('getVideoTracks'.toJS)
          .toDart
          .single;
      tracks.add(replacementTrack);
      JSObject.fromInteropObject(
        replacementStream,
      ).callMethod<JSAny?>('addTrack'.toJS, replacementTrack);
      await attachWebMediaTrack(left, replacementStream, replacementTrack);
      await applyWebSenderLimits(left, screenSettings, screenSharing: true);
      if (leftJs
              .callMethod<JSArray<JSObject>>('getTransceivers'.toJS)
              .toDart
              .length !=
          transceiverCount) {
        throw StateError('Source switching added another media section');
      }
      final beforeReplacement = await encodedFrames();
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await encodedFrames() <= beforeReplacement) {
        throw StateError('Replacement screen did not send video');
      }
      if (logs.isNotEmpty) throw StateError(logs.join('\n'));
      if (mounted) {
        setState(
          () => _report =
              'PASS: WebRTC loopback\n\nDiscovered video: ${caps.video.join(', ')}\nDiscovered audio: ${caps.audio.join(', ')}\n\nPreferred codecs: $preferredVideo / $preferredAudio\n${senderReport.join('\n')}\n\nPASS: live bitrate and frame-rate update\nPASS: screen 1 fps ($slowFrames frames / 3s), exact 777 kbps\nPASS: pause stops frames; audio stays active; resume and camera limits restored\nPASS: replacement screen reuses the video sender and sends frames\nSynthetic video/audio; no camera or microphone access.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _report = 'FAIL: $error\n${logs.join('\n')}');
    } finally {
      timer.cancel();
      for (final track in tracks) {
        track.callMethod<JSAny?>('stop'.toJS);
      }
      oscillator.callMethod<JSAny?>('stop'.toJS);
      await audio.callMethod<JSPromise<JSAny?>>('close'.toJS).toDart;
      left.close();
      right.close();
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(32),
    child: SelectableText(_report),
  );
}
