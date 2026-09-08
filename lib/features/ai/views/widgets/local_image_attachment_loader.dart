import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:plume_ai_chat/plume_ai_chat.dart' show AiImageAttachment;

class LocalImageAttachmentLoader {
  const LocalImageAttachmentLoader._();

  static final RegExp _pathControlCharacters = RegExp(
    '[\u0000\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  static const Set<String> _supportedExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.tif',
    '.tiff',
  };

  static Future<AiImageAttachment?> load(String rawText) async {
    final String candidate = _normalizePath(rawText);
    if (candidate.isEmpty ||
        !path.isAbsolute(candidate) ||
        !_supportedExtensions.contains(
          path.extension(candidate).toLowerCase(),
        )) {
      return null;
    }

    try {
      final File file = File(candidate);
      if (!await file.exists()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return null;
      }
      return AiImageAttachment(
        bytes: bytes,
        mimeType: _mimeTypeForPath(candidate),
        label: path.basename(candidate),
        sourcePath: candidate,
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizePath(String rawText) {
    String value = rawText.replaceAll(_pathControlCharacters, '').trim();
    if (value.length >= 2) {
      final String first = value[0];
      final String last = value[value.length - 1];
      final bool wrapped =
          (first == '"' && last == '"') ||
          (first == "'" && last == "'") ||
          (first == '`' && last == '`') ||
          (first == '“' && last == '”') ||
          (first == '‘' && last == '’');
      if (wrapped) {
        value = value.substring(1, value.length - 1).trim();
      }
    }

    final Uri? uri = Uri.tryParse(value);
    if (uri != null && uri.scheme.toLowerCase() == 'file') {
      try {
        return uri.toFilePath(windows: Platform.isWindows);
      } on FormatException {
        return value;
      }
    }
    return value;
  }

  static String _mimeTypeForPath(String value) {
    switch (path.extension(value).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.tif':
      case '.tiff':
        return 'image/tiff';
      case '.png':
      default:
        return 'image/png';
    }
  }
}
