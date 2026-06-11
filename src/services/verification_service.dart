import 'dart:convert';
import 'dart:typed_data';

import '../models/evidence_package.dart';
import '../utils/jpeg_meta.dart';
import 'crypto_service.dart';
import 'trust_assessment.dart';

enum VerifyStatus {
  authentic, // signature valid, image pixels + metadata unchanged
  edited, // signature genuine but the image pixels were modified
  invalid, // signature/metadata don't validate (tampered or wrong key)
  noData, // no Provenshot evidence found in/with the file
}

class VerifyResult {
  final VerifyStatus status;
  final EvidencePackage? sidecar;
  final bool signatureValid;
  final bool pixelHashMatch;
  final bool contentHashMatch;
  final String? computedPixelHash;
  final String message;
  final TrustAssessment? trust;

  VerifyResult({
    required this.status,
    this.sidecar,
    this.signatureValid = false,
    this.pixelHashMatch = false,
    this.contentHashMatch = false,
    this.computedPixelHash,
    required this.message,
    this.trust,
  });

  bool get isAuthentic => status == VerifyStatus.authentic;
}

/// Pure, on-device verification. Re-derives everything from first principles so
/// a "pass" actually means something — it does not trust any stored verdict.
class VerificationService {
  /// Verify an image. [sidecar] may be supplied explicitly (e.g. a picked
  /// `.json`); otherwise it is read from the image's embedded COM segment.
  static VerifyResult verifyImageBytes(
    Uint8List imageBytes, {
    EvidencePackage? sidecar,
  }) {
    sidecar ??= _embeddedSidecar(imageBytes);
    if (sidecar == null) {
      return VerifyResult(
        status: VerifyStatus.noData,
        message: 'No Provenshot evidence found in this image. '
            'It may not be a Provenshot photo, or the seal was stripped.',
      );
    }
    return verifyWithSidecar(imageBytes, sidecar);
  }

  static VerifyResult verifyWithSidecar(
      Uint8List imageBytes, EvidencePackage sidecar) {
    // 1. Recompute the pixel hash of the supplied image.
    final computedHash = CryptoService.pixelHashFromEncoded(imageBytes);
    if (computedHash == null) {
      return VerifyResult(
        status: VerifyStatus.invalid,
        sidecar: sidecar,
        message: 'The file could not be decoded as an image.',
      );
    }
    final pixelMatch = computedHash == sidecar.imageSha256;

    // 2. Recompute the signed payload + its hash from the sidecar fields.
    final payload = sidecar.signedPayload();
    final payloadBytes = Uint8List.fromList(utf8.encode(payload));
    final contentHashCalc = CryptoService.sha256Hex(payloadBytes);
    final contentMatch = contentHashCalc == sidecar.contentHash;

    // 3. Verify the hardware signature over the signed payload.
    bool sigValid = false;
    try {
      sigValid = CryptoService.verifySignature(
        message: payloadBytes,
        derSignature: base64Decode(sidecar.signatureB64),
        spkiPublicKey: base64Decode(sidecar.publicKeyB64),
      );
    } catch (_) {
      sigValid = false;
    }

    VerifyStatus status;
    String message;
    if (sigValid && contentMatch && pixelMatch) {
      status = VerifyStatus.authentic;
      message = 'Authentic. The image and its metadata are unchanged since it '
          'was sealed.';
    } else if (sigValid && contentMatch && !pixelMatch) {
      status = VerifyStatus.edited;
      message = 'Image edited. The signature is genuine but the photo’s pixels '
          'no longer match the sealed original.';
    } else {
      status = VerifyStatus.invalid;
      message = !sigValid
          ? 'Invalid signature. The evidence metadata was altered or the '
              'signature does not match the public key.'
          : 'Tampered. The metadata no longer matches what was signed.';
    }

    return VerifyResult(
      status: status,
      sidecar: sidecar,
      signatureValid: sigValid,
      pixelHashMatch: pixelMatch,
      contentHashMatch: contentMatch,
      computedPixelHash: computedHash,
      message: message,
      // v1: keyAttested is always false (no device-attestation validation yet),
      // so the key tier is hardware/software from the self-reported flag.
      trust: TrustAssessment.of(
        sidecar,
        contentIntact: status == VerifyStatus.authentic,
      ),
    );
  }

  static EvidencePackage? _embeddedSidecar(Uint8List imageBytes) {
    final json = JpegMeta.extractSidecar(imageBytes);
    if (json == null) return null;
    try {
      return EvidencePackage.fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }
}
