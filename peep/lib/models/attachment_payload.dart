import 'dart:convert';
import 'dart:typed_data';

import 'package:mime/mime.dart';

// Attachments travel as 4 KiB encrypted messages. An 8 MiB file expands to
// about 2,731 chunks, leaving room for ordinary messages under the signaling
// mailbox's 5,000-message per-room retention limit.
const int maxAttachmentBytes = 8 * 1024 * 1024;
const int attachmentChunkChars = 4 * 1024;

String normalizeAttachmentMimeType(String mimeType) =>
    mimeType.split(';').first.trim().toLowerCase();

bool isSupportedAttachmentMimeType(String mimeType) {
  final normalized = normalizeAttachmentMimeType(mimeType);
  final separator = normalized.indexOf('/');
  if (separator <= 0 || separator == normalized.length - 1) return false;
  final kind = normalized.substring(0, separator);
  final subtype = normalized.substring(separator + 1);
  return (kind == 'audio' || kind == 'video') &&
      RegExp(r"^[a-z0-9!#$&^_.+-]+$").hasMatch(subtype);
}

String resolveAttachmentMimeType({
  required String name,
  required Uint8List bytes,
  String? fallback,
}) {
  // WebM's container signature cannot distinguish audio from video. Preserve
  // a supported filename type before falling back to signature detection.
  final named = normalizeAttachmentMimeType(lookupMimeType(name) ?? '');
  if (isSupportedAttachmentMimeType(named)) return named;
  final detected = normalizeAttachmentMimeType(
    lookupMimeType(name, headerBytes: bytes) ?? '',
  );
  if (isSupportedAttachmentMimeType(detected)) return detected;
  return normalizeAttachmentMimeType(fallback ?? detected);
}

void validateAttachmentSize(int size) {
  if (size <= 0) {
    throw StateError('The selected audio or video file is empty.');
  }
  if (size > maxAttachmentBytes) {
    throw StateError('Attachments must be 8 MiB or smaller.');
  }
}

void validateAttachmentMetadata({
  required String name,
  required String mimeType,
  required int size,
}) {
  if (name.trim().isEmpty) {
    throw StateError('Choose an audio or video file.');
  }
  validateAttachmentSize(size);
  if (!isSupportedAttachmentMimeType(mimeType)) {
    throw StateError('Choose a valid audio or video file.');
  }
}

int attachmentDataUrlLength({required String mimeType, required int size}) =>
    'data:$mimeType;base64,'.length + ((size + 2) ~/ 3) * 4;

bool isValidAttachmentDataUrl({
  required String dataUrl,
  required String mimeType,
  required int size,
}) {
  if (size <= 0 || size > maxAttachmentBytes) return false;
  if (!isSupportedAttachmentMimeType(mimeType)) return false;
  final prefix = 'data:$mimeType;base64,';
  if (dataUrl.length !=
      attachmentDataUrlLength(mimeType: mimeType, size: size)) {
    return false;
  }
  if (!dataUrl.toLowerCase().startsWith(prefix.toLowerCase())) return false;
  try {
    return base64.decode(dataUrl.substring(prefix.length)).length == size;
  } on FormatException {
    return false;
  }
}

class IncomingAttachmentPayload {
  IncomingAttachmentPayload({
    required this.name,
    required String mimeType,
    required this.size,
  }) : mimeType = normalizeAttachmentMimeType(mimeType),
       _expectedLength = attachmentDataUrlLength(
         mimeType: normalizeAttachmentMimeType(mimeType),
         size: size,
       ) {
    validateAttachmentMetadata(name: name, mimeType: this.mimeType, size: size);
  }

  final String name;
  final String mimeType;
  final int size;
  final int _expectedLength;
  final StringBuffer _data = StringBuffer();
  int _receivedLength = 0;

  bool appendChunk(String chunk) {
    if (chunk.isEmpty || chunk.length > attachmentChunkChars) return false;
    if (_receivedLength + chunk.length > _expectedLength) return false;
    _data.write(chunk);
    _receivedLength += chunk.length;
    return true;
  }

  String? takeValidatedDataUrl() {
    if (_receivedLength != _expectedLength) return null;
    final dataUrl = _data.toString();
    return isValidAttachmentDataUrl(
          dataUrl: dataUrl,
          mimeType: mimeType,
          size: size,
        )
        ? dataUrl
        : null;
  }
}
