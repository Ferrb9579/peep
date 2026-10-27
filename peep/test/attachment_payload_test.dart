import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peep/models/attachment_payload.dart';

void main() {
  test(
    'WebM video keeps its video type despite the shared audio signature',
    () {
      expect(
        resolveAttachmentMimeType(
          name: 'clip.webm',
          bytes: Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3]),
          fallback: 'video/webm',
        ),
        'video/webm',
      );
      expect(
        resolveAttachmentMimeType(
          name: 'clip.weba',
          bytes: Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3]),
        ),
        'audio/webm',
      );
    },
  );
  test(
    'accepts valid media MIME types and rejects unrelated or malformed ones',
    () {
      expect(isSupportedAttachmentMimeType('audio/wav'), isTrue);
      expect(isSupportedAttachmentMimeType('video/webm'), isTrue);
      expect(isSupportedAttachmentMimeType('VIDEO/MP4; codecs=avc1'), isTrue);
      expect(
        isSupportedAttachmentMimeType('application/octet-stream'),
        isFalse,
      );
      expect(isSupportedAttachmentMimeType('audio/'), isFalse);
      expect(isSupportedAttachmentMimeType('audio/invalid mime'), isFalse);
    },
  );

  test('rejects empty and over-limit attachments with readable errors', () {
    expect(
      () => validateAttachmentMetadata(
        name: 'empty.wav',
        mimeType: 'audio/wav',
        size: 0,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('empty'),
        ),
      ),
    );
    expect(
      () => validateAttachmentMetadata(
        name: 'too-large.mp4',
        mimeType: 'video/mp4',
        size: maxAttachmentBytes + 1,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('8 MiB'),
        ),
      ),
    );
    expect(
      () => validateAttachmentMetadata(
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: 8,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('audio or video'),
        ),
      ),
    );
  });

  test('limits incoming chunks and validates the complete base64 payload', () {
    final bytes = Uint8List.fromList(List<int>.generate(5000, (i) => i % 256));
    final dataUrl = 'data:video/webm;base64,${base64Encode(bytes)}';
    final incoming = IncomingAttachmentPayload(
      name: 'clip.webm',
      mimeType: 'video/webm',
      size: bytes.length,
    );

    for (
      var offset = 0;
      offset < dataUrl.length;
      offset += attachmentChunkChars
    ) {
      final end = (offset + attachmentChunkChars)
          .clamp(0, dataUrl.length)
          .toInt();
      expect(incoming.appendChunk(dataUrl.substring(offset, end)), isTrue);
    }
    expect(incoming.takeValidatedDataUrl(), dataUrl);

    final oversizedChunk = IncomingAttachmentPayload(
      name: 'clip.webm',
      mimeType: 'video/webm',
      size: 1,
    );
    expect(
      oversizedChunk.appendChunk('x' * (attachmentChunkChars + 1)),
      isFalse,
    );
  });

  test('drops incomplete, oversized, and malformed incoming payloads', () {
    final incomplete = IncomingAttachmentPayload(
      name: 'tone.wav',
      mimeType: 'audio/wav',
      size: 1,
    );
    expect(incomplete.appendChunk('data:audio/wav;base64,QQ'), isTrue);
    expect(incomplete.takeValidatedDataUrl(), isNull);

    final malformed = IncomingAttachmentPayload(
      name: 'tone.wav',
      mimeType: 'audio/wav',
      size: 1,
    );
    expect(malformed.appendChunk('data:audio/wav;base64,!!!!'), isTrue);
    expect(malformed.takeValidatedDataUrl(), isNull);

    expect(
      () => IncomingAttachmentPayload(
        name: 'large.wav',
        mimeType: 'audio/wav',
        size: maxAttachmentBytes + 1,
      ),
      throwsStateError,
    );
  });
}
