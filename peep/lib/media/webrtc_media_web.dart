// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'media_settings.dart';

List<JSObject> _capabilities(String kind) {
  final sender = globalContext['RTCRtpSender'] as JSObject?;
  if (sender == null || !sender.hasProperty('getCapabilities'.toJS).toDart) {
    return [];
  }
  final caps = sender.callMethod<JSObject?>('getCapabilities'.toJS, kind.toJS);
  return (caps?['codecs'] as JSArray<JSObject>?)?.toDart ?? [];
}

String _mime(JSObject codec) =>
    (codec['mimeType'] as JSString).toDart.toLowerCase();
Future<MediaCodecSupport> discoverWebMediaCodecs() async {
  List<String> names(String kind) =>
      _capabilities(kind)
          .map(_mime)
          .where(
            (mime) => ![
              'rtx',
              'red',
              'ulpfec',
              'flexfec-03',
              'cn',
              'telephone-event',
            ].contains(mime.split('/').last),
          )
          .toSet()
          .toList()
        ..sort();
  return MediaCodecSupport(video: names('video'), audio: names('audio'));
}

Future<void> applyWebCodecPreferences(
  html.RtcPeerConnection connection,
  MediaSettings settings,
  void Function(String) onLog,
) async {
  final pc = JSObject.fromInteropObject(connection);
  if (!pc.hasProperty('getTransceivers'.toJS).toDart) return;
  for (final transceiver
      in pc.callMethod<JSArray<JSObject>>('getTransceivers'.toJS).toDart) {
    if (!transceiver.hasProperty('setCodecPreferences'.toJS).toDart) continue;
    final sender = transceiver['sender'] as JSObject;
    final receiver = transceiver['receiver'] as JSObject;
    final track = (sender['track'] ?? receiver['track']) as JSObject?;
    final kind = (track?['kind'] as JSString?)?.toDart;
    if (kind != 'video' && kind != 'audio') continue;
    try {
      final codecs = _capabilities(kind!);
      final preferred = kind == 'video'
          ? settings.videoCodec
          : settings.audioCodec;
      if (codecs.isNotEmpty) {
        transceiver.callMethod<JSAny?>(
          'setCodecPreferences'.toJS,
          prioritizeCodecs(codecs, preferred, _mime).toJS,
        );
      }
    } catch (error) {
      onLog(
        'Codec preference could not be applied; using negotiated defaults: $error',
      );
    }
  }
}

Future<void> applyWebSenderLimits(
  html.RtcPeerConnection connection,
  MediaSettings settings, {
  bool screenSharing = false,
  bool screenPaused = false,
}) async {
  final pc = JSObject.fromInteropObject(connection);
  for (final sender
      in pc.callMethod<JSArray<JSObject>>('getSenders'.toJS).toDart) {
    final track = sender['track'] as JSObject?;
    final kind = (track?['kind'] as JSString?)?.toDart;
    if (kind != 'video' && kind != 'audio') continue;
    final parameters = sender.callMethod<JSObject>('getParameters'.toJS);
    final encodings =
        (parameters['encodings'] as JSArray<JSObject>?)?.toDart ?? [];
    if (encodings.isEmpty) {
      throw StateError('The $kind sender has not negotiated an encoding yet.');
    }
    for (final encoding in encodings) {
      encoding['maxBitrate'] =
          ((kind == 'video'
                      ? (screenSharing
                            ? settings.screenBitrateKbps
                            : settings.videoBitrateKbps)
                      : settings.audioBitrateKbps) *
                  1000)
              .toJS;
      if (kind == 'video') {
        encoding['maxFramerate'] =
            (screenSharing ? settings.screenFrameRate : settings.frameRate)
                .toJS;
        encoding['active'] = (!screenSharing || !screenPaused).toJS;
      }
    }
    await sender
        .callMethod<JSPromise<JSAny?>>('setParameters'.toJS, parameters)
        .toDart;
  }
}

Future<void> applyWebScreenConstraints(
  html.MediaStream stream,
  MediaSettings settings,
) async {
  for (final track in stream.getVideoTracks()) {
    await JSObject.fromInteropObject(track)
        .callMethod<JSPromise<JSAny?>>(
          'applyConstraints'.toJS,
          settings.screenConstraints.jsify(),
        )
        .toDart;
  }
}

/// Reuse the negotiated media section when switching camera/screen sources.
/// Leaving stopped senders attached creates extra remote video tracks.
Future<void> attachWebMediaTrack(
  html.RtcPeerConnection connection,
  html.MediaStream stream,
  JSObject track,
) async {
  final pc = JSObject.fromInteropObject(connection);
  final kind = (track['kind'] as JSString).toDart;
  for (final transceiver
      in pc.callMethod<JSArray<JSObject>>('getTransceivers'.toJS).toDart) {
    final sender = transceiver['sender'] as JSObject;
    final existing = sender['track'] as JSObject?;
    final receiver = transceiver['receiver'] as JSObject;
    final receiverTrack = receiver['track'] as JSObject?;
    if (((existing ?? receiverTrack)?['kind'] as JSString?)?.toDart != kind) {
      continue;
    }
    await sender
        .callMethod<JSPromise<JSAny?>>('replaceTrack'.toJS, track)
        .toDart;
    sender.callMethod<JSAny?>(
      'setStreams'.toJS,
      JSObject.fromInteropObject(stream),
    );
    transceiver['direction'] = 'sendrecv'.toJS;
    return;
  }
  pc.callMethod<JSAny?>(
    'addTrack'.toJS,
    track,
    JSObject.fromInteropObject(stream),
  );
}

Future<void> detachWebVideoSenders(html.RtcPeerConnection connection) async {
  final pc = JSObject.fromInteropObject(connection);
  for (final transceiver
      in pc.callMethod<JSArray<JSObject>>('getTransceivers'.toJS).toDart) {
    final sender = transceiver['sender'] as JSObject;
    final track = sender['track'] as JSObject?;
    if ((track?['kind'] as JSString?)?.toDart != 'video') continue;
    await sender.callMethodVarArgs<JSPromise<JSAny?>>('replaceTrack'.toJS, [
      null,
    ]).toDart;
    transceiver['direction'] = 'recvonly'.toJS;
  }
}
