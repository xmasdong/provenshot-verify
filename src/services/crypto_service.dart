import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;
import 'package:pointycastle/export.dart';

/// Pure-Dart cryptographic verification. Signing happens in hardware via the
/// platform channel (see [SecureSigner]); verification is portable so it works
/// off the original device (and mirrors the future Web Crypto verify page).
class CryptoService {
  CryptoService._();

  static final ECDomainParameters _p256 = ECDomainParameters('prime256v1');

  /// Domain-separated SHA-256 over the *decoded RGBA pixels* of an image.
  ///
  /// Computed from a decoded [img.Image] so it is independent of container
  /// metadata (EXIF/XMP) — embedding the sidecar into the file does not change
  /// it, but any pixel edit or re-encode does. The width/height/channels are
  /// folded in to remove any dimension ambiguity.
  static String pixelHashFromImage(img.Image image) {
    final rgba = image.getBytes(order: img.ChannelOrder.rgba);
    final header = ascii.encode('PSPX1\n${image.width}\n${image.height}\n4\n');
    final collector = _CollectingSink();
    final input = crypto.sha256.startChunkedConversion(collector);
    input.add(header);
    input.add(rgba);
    input.close();
    return _hex(collector.digest!.bytes);
  }

  /// Decode the given encoded image bytes (JPEG/PNG) and compute the pixel hash.
  /// Returns null if the bytes are not a decodable image.
  static String? pixelHashFromEncoded(Uint8List encoded) {
    final image = img.decodeImage(encoded);
    if (image == null) return null;
    return pixelHashFromImage(image);
  }

  static String sha256Hex(List<int> bytes) =>
      _hex(crypto.sha256.convert(bytes).bytes);

  /// keyId = first 16 bytes of SHA-256(SPKI public key), hex.
  static String keyIdFromPublicKey(Uint8List spki) {
    final d = crypto.sha256.convert(spki).bytes;
    return _hex(d.sublist(0, 16));
  }

  /// Verify an ECDSA P-256 / SHA-256 signature.
  ///
  /// [message] is the canonical signed payload bytes; [derSignature] is the
  /// ASN.1 DER ECDSA signature; [spkiPublicKey] is X.509 SubjectPublicKeyInfo.
  /// Native signers (`ecdsaSignatureMessageX962SHA256` on iOS,
  /// `SHA256withECDSA` on Android) hash the message with SHA-256 internally, so
  /// we verify the signature against SHA-256(message).
  static bool verifySignature({
    required Uint8List message,
    required Uint8List derSignature,
    required Uint8List spkiPublicKey,
  }) {
    try {
      final pub = _parseSpkiP256PublicKey(spkiPublicKey);
      final sig = _parseDerEcdsaSignature(derSignature);
      final digest = Uint8List.fromList(crypto.sha256.convert(message).bytes);
      final signer = ECDSASigner();
      signer.init(false, PublicKeyParameter<ECPublicKey>(pub));
      return signer.verifySignature(digest, sig);
    } catch (_) {
      return false;
    }
  }

  static ECPublicKey _parseSpkiP256PublicKey(Uint8List spki) {
    // A P-256 SubjectPublicKeyInfo ends with the 65-byte uncompressed point
    // (0x04 || X(32) || Y(32)). Extract it robustly without depending on
    // BIT STRING quirks across asn1lib versions.
    if (spki.length < 65) {
      throw ArgumentError('public key too short');
    }
    final point = spki.sublist(spki.length - 65);
    if (point[0] != 0x04) {
      // Fall back to ASN.1 parsing if the tail heuristic fails.
      return _parseSpkiViaAsn1(spki);
    }
    final q = _p256.curve.decodePoint(point);
    if (q == null) throw ArgumentError('invalid EC point');
    return ECPublicKey(q, _p256);
  }

  static ECPublicKey _parseSpkiViaAsn1(Uint8List spki) {
    final parser = ASN1Parser(spki);
    final seq = parser.nextObject() as ASN1Sequence;
    final bitString = seq.elements[1] as ASN1BitString;
    var bytes = Uint8List.fromList(bitString.contentBytes());
    // Strip a leading "unused bits" byte if present.
    if (bytes.isNotEmpty && bytes[0] == 0x00 && bytes.length == 66) {
      bytes = bytes.sublist(1);
    }
    final start = bytes.indexOf(0x04);
    final point = bytes.sublist(start, start + 65);
    final q = _p256.curve.decodePoint(point);
    if (q == null) throw ArgumentError('invalid EC point');
    return ECPublicKey(q, _p256);
  }

  static ECSignature _parseDerEcdsaSignature(Uint8List der) {
    final parser = ASN1Parser(der);
    final seq = parser.nextObject() as ASN1Sequence;
    final r = (seq.elements[0] as ASN1Integer).valueAsBigInteger;
    final s = (seq.elements[1] as ASN1Integer).valueAsBigInteger;
    return ECSignature(r, s);
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// Minimal sink that collects a single chunked digest result.
class _CollectingSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;
  @override
  void add(crypto.Digest data) => digest = data;
  @override
  void close() {}
}
