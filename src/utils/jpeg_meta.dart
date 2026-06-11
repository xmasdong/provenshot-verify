import 'dart:convert';
import 'dart:typed_data';

/// Embeds / extracts the evidence sidecar in a JPEG **without re-encoding** by
/// inserting a COM (comment, 0xFFFE) segment right after SOI. Because the
/// entropy-coded pixel data is untouched, the pixel hash stays stable — so a
/// self-contained sealed file still verifies, satisfying the "embed signature
/// in the image" requirement losslessly.
class JpegMeta {
  static const String _tag = 'PROVENSHOT1:';

  static bool isJpeg(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  static Uint8List injectSidecar(Uint8List jpg, String sidecarJson) {
    if (!isJpeg(jpg)) return jpg;
    final payload = utf8.encode('$_tag$sidecarJson');
    if (payload.length > 65533) return jpg; // COM length field is 16-bit
    final len = payload.length + 2;
    final out = BytesBuilder();
    out.add([0xFF, 0xD8]); // SOI
    out.add([0xFF, 0xFE, (len >> 8) & 0xFF, len & 0xFF]); // COM marker + length
    out.add(payload);
    out.add(jpg.sublist(2));
    return out.toBytes();
  }

  static String? extractSidecar(Uint8List jpg) {
    if (!isJpeg(jpg)) return null;
    var i = 2;
    while (i + 2 <= jpg.length) {
      if (jpg[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = jpg[i + 1];
      if (marker == 0xD9 || marker == 0xDA) break; // EOI / start of scan
      // Standalone markers (no length payload).
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (i + 4 > jpg.length) break;
      final len = (jpg[i + 2] << 8) | jpg[i + 3];
      if (marker == 0xFE) {
        final start = i + 4;
        final end = start + (len - 2);
        if (end <= jpg.length) {
          final text = utf8.decode(jpg.sublist(start, end), allowMalformed: true);
          if (text.startsWith(_tag)) return text.substring(_tag.length);
        }
      }
      i += 2 + len;
    }
    return null;
  }
}
