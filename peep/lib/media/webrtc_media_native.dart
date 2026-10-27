import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'media_settings.dart';

Future<MediaCodecSupport> discoverNativeMediaCodecs() async {
  final video = await getRtpSenderCapabilities('video');
  final audio = await getRtpSenderCapabilities('audio');
  List<String> names(RTCRtpCapabilities caps) =>
      (caps.codecs ?? [])
          .map((codec) => codec.mimeType.toLowerCase())
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
  return MediaCodecSupport(video: names(video), audio: names(audio));
}

Map<String, dynamic> nativeVideoConstraints(MediaSettings settings) => {
  'width': settings.videoQuality.width,
  'height': settings.videoQuality.height,
  'frameRate': settings.frameRate,
  'facingMode': 'user',
};
Map<String, dynamic> nativeScreenConstraints(MediaSettings settings) => {
  if (settings.screenQuality.width != null)
    'width': settings.screenQuality.width,
  if (settings.screenQuality.height != null)
    'height': settings.screenQuality.height,
  'frameRate': settings.screenFrameRate,
};
Map<String, dynamic> nativeAudioConstraints(MediaSettings settings) => {
  'sampleRate': settings.sampleRate,
  'channelCount': settings.stereo ? 2 : 1,
  'mandatory': <String, dynamic>{},
  'optional': [
    {'googEchoCancellation': settings.echoCancellation},
    {'googEchoCancellation2': settings.echoCancellation},
    {'googNoiseSuppression': settings.noiseSuppression},
    {'googAutoGainControl': settings.autoGainControl},
    {'echoCancellation': settings.echoCancellation},
  ],
};

Future<void> applyNativeCodecPreferences(
  RTCPeerConnection connection,
  MediaSettings settings,
  void Function(String) onLog,
) async {
  for (final transceiver in await connection.getTransceivers()) {
    final kind =
        transceiver.sender.track?.kind ?? transceiver.receiver.track?.kind;
    if (kind != 'video' && kind != 'audio') continue;
    try {
      final caps = await getRtpSenderCapabilities(kind!);
      final codecs = caps.codecs ?? [];
      final preferred = kind == 'video'
          ? settings.videoCodec
          : settings.audioCodec;
      await transceiver.setCodecPreferences(
        prioritizeCodecs(codecs, preferred, (codec) => codec.mimeType),
      );
    } catch (error) {
      onLog(
        'Codec preference could not be applied; using negotiated defaults: $error',
      );
    }
  }
}

/// Read fresh parameters each time; preserve negotiated encodings and codecs.
Future<void> applyNativeSenderLimits(
  RTCPeerConnection connection,
  MediaSettings settings, {
  bool screenSharing = false,
  bool screenPaused = false,
}) async {
  for (final sender in await connection.getSenders()) {
    final kind = sender.track?.kind;
    if (kind != 'video' && kind != 'audio') continue;
    final parameters = sender.parameters;
    final encodings = parameters.encodings;
    if (encodings == null || encodings.isEmpty) {
      throw StateError('The $kind sender has not negotiated an encoding yet.');
    }
    for (final encoding in encodings) {
      encoding.maxBitrate =
          (kind == 'video'
              ? (screenSharing
                    ? settings.screenBitrateKbps
                    : settings.videoBitrateKbps)
              : settings.audioBitrateKbps) *
          1000;
      if (kind == 'video') {
        encoding.maxFramerate = screenSharing
            ? settings.screenFrameRate
            : settings.frameRate;
        encoding.active = !screenSharing || !screenPaused;
      }
    }
    if (!await sender.setParameters(parameters)) {
      throw StateError('The device rejected the $kind sender limits.');
    }
  }
}

Future<void> attachNativeMediaTrack(
  RTCPeerConnection connection,
  MediaStream stream,
  MediaStreamTrack track,
) async {
  for (final transceiver in await connection.getTransceivers()) {
    if ((transceiver.sender.track?.kind ?? transceiver.receiver.track?.kind) !=
        track.kind) {
      continue;
    }
    await transceiver.sender.replaceTrack(track);
    await transceiver.sender.setStreams([stream]);
    await transceiver.setDirection(TransceiverDirection.SendRecv);
    return;
  }
  await connection.addTrack(track, stream);
}

Future<void> detachNativeVideoSenders(RTCPeerConnection connection) async {
  for (final transceiver in await connection.getTransceivers()) {
    if (transceiver.sender.track?.kind != 'video') continue;
    await transceiver.sender.replaceTrack(null);
    await transceiver.setDirection(TransceiverDirection.RecvOnly);
  }
}
