// Web verify entrypoint. Compiles the EXISTING pure-Dart verifier to JS with
// `dart compile js`, so the browser runs byte-for-byte the same code as the
// app: the same `image` JPEG decoder, the same RGBA pixel hash, and the same
// pointycastle ECDSA P-256 check. That guarantees parity — a hand-ported JS
// decoder cannot reproduce the Dart `image` package's pixels exactly.
//
// Exposes window.provenshotVerify(imageBase64, sidecarJsonOrEmpty) -> JSON.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'models/evidence_package.dart';
import 'services/verification_service.dart';

String _verify(String imageB64, String sidecarJsonOrEmpty) {
  final bytes = base64Decode(imageB64);
  EvidencePackage? sidecar;
  if (sidecarJsonOrEmpty.trim().isNotEmpty) {
    try {
      sidecar = EvidencePackage.fromJson(jsonDecode(sidecarJsonOrEmpty));
    } catch (_) {
      sidecar = null;
    }
  }
  final r = VerificationService.verifyImageBytes(
    Uint8List.fromList(bytes),
    sidecar: sidecar,
  );
  final s = r.sidecar;
  return jsonEncode({
    'status': r.status.name,
    'signatureValid': r.signatureValid,
    'pixelHashMatch': r.pixelHashMatch,
    'contentHashMatch': r.contentHashMatch,
    'computedPixelHash': r.computedPixelHash,
    'message': r.message,
    'trust': r.trust?.toJson(),
    'sidecar': s?.toJson(),
  });
}

@JS('provenshotVerify')
external set _exported(JSFunction f);

void main() {
  _exported = ((JSString imageB64, JSString sidecarJson) =>
      _verify(imageB64.toDart, sidecarJson.toDart).toJS).toJS;
}
