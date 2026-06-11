# Provenshot Evidence Format — Verification Specification

Version: schema `1.0` · Status: shipping format of the Provenshot app

This document specifies, byte-for-byte, how a Provenshot sealed photo is
structured and how to verify it **independently** — without Provenshot's app,
website, or cooperation. The verification source code in [`src/`](src/) is the
reference implementation (the same Dart code runs inside the app and, compiled
to JS, on this site's [verify page](https://provenshot.app/verify)).

Security does not depend on any secret in this document. The cryptography is
entirely standard: SHA-256, ECDSA P-256, X.509 SubjectPublicKeyInfo, ASN.1 DER.

---

## 1. Container: where the evidence record lives

A sealed photo is an ordinary JPEG. The evidence record ("sidecar") is a JSON
document embedded in a JPEG **COM segment** (marker `0xFFFE`) inserted
immediately after the SOI marker:

```
FF D8                      SOI
FF FE <len_hi> <len_lo>    COM, big-endian 16-bit length (payload + 2)
"PROVENSHOT1:" + <sidecar JSON, UTF-8>
... rest of the original JPEG, untouched ...
```

- Payload prefix: ASCII `PROVENSHOT1:`, then the sidecar JSON (UTF-8).
- Max payload: 65 533 bytes (16-bit COM length).
- The entropy-coded image data is **not** re-encoded when embedding, so
  embedding does not change the decoded pixels.
- Extraction: scan JPEG segments from SOI; stop at SOS (`0xFFDA`) or EOI
  (`0xFFD9`); the first COM whose text starts with `PROVENSHOT1:` is the
  sidecar. Reference: [`src/utils/jpeg_meta.dart`](src/utils/jpeg_meta.dart).

The same JSON is also exported as a standalone `*.provenshot.json` file in
evidence packs; either source is equivalent.

## 2. Sidecar JSON (stored form)

Top-level keys: `schemaVersion`, `id`, `verifyId`, `image{fileName, sha256,
width, height}`, `capture{capturedAtUtc, timeZoneId, tzOffsetMinutes,
timeSource, location, address, addressEdited, locationTrust, trustReasons,
weather, projectName, note, device}`, `crypto{hashAlgorithm,
signatureAlgorithm, contentHash, signature, publicKey, keyId, secureHardware}`,
`display{...}`.

- `crypto.publicKey` — base64 X.509 SubjectPublicKeyInfo (P-256, uncompressed
  point).
- `crypto.signature` — base64 ASN.1 DER ECDSA signature.
- `crypto.keyId` — hex of the first 16 bytes of SHA-256(SPKI).
- `display.*` is cosmetic and **not** covered by the signature.

## 3. Pixel hash (`image.sha256`, domain `rgba-pixels-v1`)

SHA-256 over a domain-separation header plus the decoded RGBA pixels:

```
SHA-256( ASCII("PSPX1\n{width}\n{height}\n4\n") || RGBA bytes, row-major )
```

This is a hash of **decoded pixels**, not file bytes — so embedding the
sidecar (Section 1) or editing EXIF does not change it, while any pixel edit
or re-encode does.

**Decoder pinning (important).** JPEG decoders differ in IDCT/chroma rounding,
so the RGBA bytes — and therefore the hash — are defined relative to a pinned
open-source decoder: the Dart [`image`](https://pub.dev/packages/image)
package (v4.x), as used in
[`src/services/crypto_service.dart`](src/services/crypto_service.dart).
An independent implementation must use this decoder (it is MIT-licensed and
compiles to JS/native/WASM). We empirically verified that browser canvas and
jpeg-js outputs do NOT byte-match; that is why the verify page runs the
compiled reference decoder instead of a hand port.

## 4. Signed payload (the message under the signature)

The signature does **not** cover the sidecar JSON verbatim. It covers a
**canonical JSON** message rebuilt from the sidecar fields:

```json
{
  "capture": {
    "address": "...",
    "addressEdited": false,
    "capturedAtUtc": "2026-06-09T03:21:45.123Z",
    "location": {
      "accuracy": "12.00",
      "altitude": "14.20",
      "heading": "47.0",
      "lat": "39.907340",
      "lon": "116.390890"
    },
    "locationTrust": "ok",
    "note": null,
    "projectName": null,
    "timeSource": "device",
    "timeZoneId": "Asia/Shanghai",
    "trustReasons": [],
    "tzOffsetMinutes": 480,
    "weather": null
  },
  "device": {
    "appInstanceId": "...",
    "appVersion": "...",
    "model": "...",
    "osVersion": "...",
    "platform": "ios"
  },
  "image": {
    "hashAlg": "SHA-256",
    "hashDomain": "rgba-pixels-v1",
    "height": 3024,
    "sha256": "<pixel hash, hex>",
    "width": 4032
  },
  "schemaVersion": "1.0"
}
```

Canonicalization rules
([`src/utils/canonical_json.dart`](src/utils/canonical_json.dart)):

1. Object keys sorted lexicographically, recursively.
2. No whitespace.
3. `null` values are kept (binds the full schema).
4. `capturedAtUtc` is the UTC ISO-8601 string exactly as stored.
5. `trustReasons` is sorted.
6. **All GPS doubles are fixed-precision STRINGS**, not JSON numbers:
   lat/lon `toStringAsFixed(6)`, accuracy/altitude `toStringAsFixed(2)`,
   heading `toStringAsFixed(1)`. (Rationale: dart2js — like JavaScript —
   cannot distinguish `5.0` from `5`, so float-formatted numbers are not
   portable across runtimes. Strings are.)

`crypto.contentHash` = hex SHA-256 of the UTF-8 canonical payload (a
convenience copy; recompute it, don't trust it).

## 5. Signature

- Algorithm: ECDSA P-256 with SHA-256 (`ECDSA-P256-SHA256`).
  iOS signs via Secure Enclave (`ecdsaSignatureMessageX962SHA256`);
  Android via Keystore `SHA256withECDSA`. Both hash the message internally:
  the signature is over SHA-256(canonical payload bytes).
- Verify with any standard library. OpenSSL:

```sh
# payload.json = canonical payload bytes (Section 4)
# pub.pem      = crypto.publicKey wrapped in PEM ("-----BEGIN PUBLIC KEY-----")
# sig.der      = base64-decoded crypto.signature
openssl dgst -sha256 -verify pub.pem -signature sig.der payload.json
```

## 6. Verification algorithm

1. Extract the sidecar (Section 1) or take the standalone JSON.
2. Decode the JPEG with the pinned decoder; compute the pixel hash
   (Section 3); compare to `image.sha256`.
3. Rebuild the canonical payload (Section 4) from the sidecar fields.
4. Verify the ECDSA signature (Section 5) with `crypto.publicKey`.
5. Verdict:
   - hash matches ∧ signature valid → **authentic** (content unchanged since
     sealing, by the key in `crypto.publicKey`);
   - signature valid ∧ hash mismatch → **edited** (genuine seal, pixels
     changed);
   - signature invalid → **invalid** (record tampered or wrong key);
   - no sidecar → **no data**.

## 7. What verification proves — and what it cannot

Proves: the pixels and every signed field (time, GPS, address, device) are
**unchanged since sealing**, and were sealed by the holder of the private key
(hardware-backed when `crypto.secureHardware` is true — note this field is
self-reported by the capturing app).

Cannot prove (disclosed in the app's trust panel by design):

- the device clock was correct (`timeSource: "device"`; no trusted timestamp
  in schema 1.0);
- the GPS was not spoofed by a compromised OS (capture-time mock-location
  detection only → `locationTrust`);
- the key truly lives in genuine hardware / an unmodified app (no remote
  attestation in schema 1.0 — a re-signed forgery from a modified app would
  verify against ITS key, which is why key identity matters);
- the photographed scene is real (a photo of a screen seals fine).

Honest wording is part of the format: a verifier UI should say
**"tamper-evident"**, never "tamper-proof".

## 8. Reference implementation

| Path | Role |
| --- | --- |
| `src/services/crypto_service.dart` | pixel hash + ECDSA verify (pure Dart) |
| `src/utils/canonical_json.dart` | canonical JSON encoder |
| `src/utils/jpeg_meta.dart` | COM-segment embed/extract |
| `src/models/evidence_package.dart` | sidecar model + signed-payload builder |
| `src/services/verification_service.dart` | full verify flow + verdicts |
| `src/services/trust_assessment.dart` | proves / can't-prove panel logic |
| `src/verify_web.dart` | JS entrypoint compiled into `verify/verifier.js` |

Build the web verifier yourself and diff it against the deployed one:

```sh
dart pub get
dart compile js src/verify_web.dart -o verifier.js -O2
```
