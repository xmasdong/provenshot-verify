import '../utils/canonical_json.dart';

/// One geolocation fix captured at shutter time.
class GeoPoint {
  final double latitude;
  final double longitude;
  final double? accuracy; // metres
  final double? altitude; // metres
  final double? heading; // degrees, 0..360
  final double? speed; // m/s

  const GeoPoint({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.altitude,
    this.heading,
    this.speed,
  });

  /// Bound fields for the signed payload, formatted as fixed-precision STRINGS.
  ///
  /// Strings (not doubles) are used deliberately so the canonical bytes are
  /// byte-identical on every platform. dart2js (the web verify page) unifies
  /// `5.0` and `5` into one JS number, so a double `5.0` would serialize as
  /// "5" on the web but "5.0" on the mobile (Dart VM) signer — breaking the
  /// signature. `toStringAsFixed` is spec'd identically across VM and JS.
  Map<String, dynamic> toSignedJson() => {
        'lat': latitude.toStringAsFixed(6),
        'lon': longitude.toStringAsFixed(6),
        'accuracy': accuracy?.toStringAsFixed(2),
        'altitude': altitude?.toStringAsFixed(2),
        'heading': heading?.toStringAsFixed(1),
      };

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'heading': heading,
        'speed': speed,
      };

  factory GeoPoint.fromJson(Map<String, dynamic> j) => GeoPoint(
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        accuracy: (j['accuracy'] as num?)?.toDouble(),
        altitude: (j['altitude'] as num?)?.toDouble(),
        heading: (j['heading'] as num?)?.toDouble(),
        speed: (j['speed'] as num?)?.toDouble(),
      );
}

class DeviceInfoData {
  final String platform; // 'ios' | 'android'
  final String model;
  final String osVersion;
  final String appInstanceId; // stable per install (uuid)
  final String appVersion;

  const DeviceInfoData({
    required this.platform,
    required this.model,
    required this.osVersion,
    required this.appInstanceId,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'model': model,
        'osVersion': osVersion,
        'appInstanceId': appInstanceId,
        'appVersion': appVersion,
      };

  factory DeviceInfoData.fromJson(Map<String, dynamic> j) => DeviceInfoData(
        platform: j['platform'] ?? '',
        model: j['model'] ?? '',
        osVersion: j['osVersion'] ?? '',
        appInstanceId: j['appInstanceId'] ?? '',
        appVersion: j['appVersion'] ?? '',
      );
}

/// Trust verdict for the captured location.
enum LocationTrust { ok, suspect, unknown }

extension LocationTrustX on LocationTrust {
  String get id => name;
  static LocationTrust fromId(String? id) => LocationTrust.values
      .firstWhere((e) => e.name == id, orElse: () => LocationTrust.unknown);
}

/// The complete, self-describing evidence record (the "sidecar").
///
/// Tamper-evidence design:
///  - [imageSha256] is the SHA-256 of the *decoded RGBA pixels* of the sealed
///    image (EXIF-independent: embedding the sidecar into EXIF does not change
///    it, but any pixel edit / re-encode does).
///  - [signedPayload] is a canonical JSON of all bound fields (including
///    imageSha256). [contentHash] = SHA-256(signedPayload).
///  - [signature] is an ECDSA P-256 signature (DER) over [signedPayload],
///    produced by a hardware-backed key (Secure Enclave / Android Keystore).
///  - [publicKey] is the X.509 SubjectPublicKeyInfo (DER) so any standard
///    verifier (incl. Web Crypto in the phase-2 verify page) can check it.
class EvidencePackage {
  static const String schemaVersion = '1.0';

  final String id; // local uuid (not bound)
  final String? verifyId; // reserved for phase-2 online verify page (not bound)

  // ---- image ----
  final String imageFileName;
  final String imageSha256; // hex
  final int imageWidth;
  final int imageHeight;

  // ---- capture metadata (bound) ----
  final DateTime capturedAtUtc;
  final String timeZoneId; // IANA, e.g. America/Los_Angeles
  final int tzOffsetMinutes;
  final String timeSource; // 'device' (phase-2: 'tsa')
  final GeoPoint? location;
  final String address; // user-editable before sealing
  final bool addressEdited;
  final LocationTrust locationTrust;
  final List<String> trustReasons;
  final String? weather;
  final String? projectName;
  final String? note;
  final DeviceInfoData device;

  // ---- crypto (not bound; these authenticate the bound payload) ----
  final String hashAlgorithm; // 'SHA-256'
  final String signatureAlgorithm; // 'ECDSA-P256-SHA256'
  final String contentHash; // hex SHA-256(signedPayload)
  final String signatureB64; // DER signature, base64
  final String publicKeyB64; // SPKI DER, base64
  final String keyId; // first 16 bytes of SHA-256(publicKey), hex
  final bool secureHardware; // key lives in Secure Enclave / TEE / StrongBox

  // ---- display only ----
  final String templateId;
  // The sealed image bakes in a front-camera "operator" selfie (the hash covers
  // it, so this is a convenience flag, not a separate trust claim).
  final bool hasOperatorSelfie;

  const EvidencePackage({
    required this.id,
    this.verifyId,
    required this.imageFileName,
    required this.imageSha256,
    required this.imageWidth,
    required this.imageHeight,
    required this.capturedAtUtc,
    required this.timeZoneId,
    required this.tzOffsetMinutes,
    this.timeSource = 'device',
    required this.location,
    required this.address,
    required this.addressEdited,
    required this.locationTrust,
    required this.trustReasons,
    this.weather,
    this.projectName,
    this.note,
    required this.device,
    this.hashAlgorithm = 'SHA-256',
    this.signatureAlgorithm = 'ECDSA-P256-SHA256',
    required this.contentHash,
    required this.signatureB64,
    required this.publicKeyB64,
    required this.keyId,
    required this.secureHardware,
    this.templateId = 'classic',
    this.hasOperatorSelfie = false,
  });

  /// Builds the exact bytes that get hashed and signed. Deterministic: any
  /// verifier reconstructs this identically from the stored fields.
  ///
  /// This is a *static* builder so verification can compute the payload from a
  /// decoded sidecar without trusting a stored copy of the string.
  static String buildSignedPayload({
    required String imageSha256,
    required int imageWidth,
    required int imageHeight,
    required DateTime capturedAtUtc,
    required String timeZoneId,
    required int tzOffsetMinutes,
    required String timeSource,
    required GeoPoint? location,
    required String address,
    required bool addressEdited,
    required LocationTrust locationTrust,
    required List<String> trustReasons,
    required String? weather,
    required String? projectName,
    required String? note,
    required DeviceInfoData device,
  }) {
    final sortedReasons = [...trustReasons]..sort();
    final map = {
      'schemaVersion': schemaVersion,
      'image': {
        'sha256': imageSha256,
        'width': imageWidth,
        'height': imageHeight,
        'hashAlg': 'SHA-256',
        'hashDomain': 'rgba-pixels-v1',
      },
      'capture': {
        'capturedAtUtc': capturedAtUtc.toUtc().toIso8601String(),
        'timeZoneId': timeZoneId,
        'tzOffsetMinutes': tzOffsetMinutes,
        'timeSource': timeSource,
        'location': location?.toSignedJson(),
        'address': address,
        'addressEdited': addressEdited,
        'locationTrust': locationTrust.id,
        'trustReasons': sortedReasons,
        'weather': weather,
        'projectName': projectName,
        'note': note,
      },
      'device': device.toJson(),
    };
    return canonicalJsonEncode(map);
  }

  /// The signed payload for *this* package (uses its stored field values).
  String signedPayload() => buildSignedPayload(
        imageSha256: imageSha256,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        capturedAtUtc: capturedAtUtc,
        timeZoneId: timeZoneId,
        tzOffsetMinutes: tzOffsetMinutes,
        timeSource: timeSource,
        location: location,
        address: address,
        addressEdited: addressEdited,
        locationTrust: locationTrust,
        trustReasons: trustReasons,
        weather: weather,
        projectName: projectName,
        note: note,
        device: device,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'verifyId': verifyId,
        'image': {
          'fileName': imageFileName,
          'sha256': imageSha256,
          'width': imageWidth,
          'height': imageHeight,
        },
        'capture': {
          'capturedAtUtc': capturedAtUtc.toUtc().toIso8601String(),
          'timeZoneId': timeZoneId,
          'tzOffsetMinutes': tzOffsetMinutes,
          'timeSource': timeSource,
          'location': location?.toJson(),
          'address': address,
          'addressEdited': addressEdited,
          'locationTrust': locationTrust.id,
          'trustReasons': trustReasons,
          'weather': weather,
          'projectName': projectName,
          'note': note,
          'device': device.toJson(),
        },
        'crypto': {
          'hashAlgorithm': hashAlgorithm,
          'signatureAlgorithm': signatureAlgorithm,
          'contentHash': contentHash,
          'signature': signatureB64,
          'publicKey': publicKeyB64,
          'keyId': keyId,
          'secureHardware': secureHardware,
        },
        'display': {
          'templateId': templateId,
          'hasOperatorSelfie': hasOperatorSelfie,
        },
      };

  factory EvidencePackage.fromJson(Map<String, dynamic> j) {
    final image = Map<String, dynamic>.from(j['image'] ?? const {});
    final capture = Map<String, dynamic>.from(j['capture'] ?? const {});
    final crypto = Map<String, dynamic>.from(j['crypto'] ?? const {});
    final display = Map<String, dynamic>.from(j['display'] ?? const {});
    return EvidencePackage(
      id: j['id'] ?? '',
      verifyId: j['verifyId'],
      imageFileName: image['fileName'] ?? '',
      imageSha256: image['sha256'] ?? '',
      imageWidth: (image['width'] as num?)?.toInt() ?? 0,
      imageHeight: (image['height'] as num?)?.toInt() ?? 0,
      capturedAtUtc:
          DateTime.parse(capture['capturedAtUtc']).toUtc(),
      timeZoneId: capture['timeZoneId'] ?? 'UTC',
      tzOffsetMinutes: (capture['tzOffsetMinutes'] as num?)?.toInt() ?? 0,
      timeSource: capture['timeSource'] ?? 'device',
      location: capture['location'] == null
          ? null
          : GeoPoint.fromJson(Map<String, dynamic>.from(capture['location'])),
      address: capture['address'] ?? '',
      addressEdited: capture['addressEdited'] ?? false,
      locationTrust: LocationTrustX.fromId(capture['locationTrust']),
      trustReasons: (capture['trustReasons'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      weather: capture['weather'],
      projectName: capture['projectName'],
      note: capture['note'],
      device: DeviceInfoData.fromJson(
          Map<String, dynamic>.from(capture['device'] ?? const {})),
      hashAlgorithm: crypto['hashAlgorithm'] ?? 'SHA-256',
      signatureAlgorithm: crypto['signatureAlgorithm'] ?? 'ECDSA-P256-SHA256',
      contentHash: crypto['contentHash'] ?? '',
      signatureB64: crypto['signature'] ?? '',
      publicKeyB64: crypto['publicKey'] ?? '',
      keyId: crypto['keyId'] ?? '',
      secureHardware: crypto['secureHardware'] ?? false,
      templateId: display['templateId'] ?? 'classic',
      hasOperatorSelfie: display['hasOperatorSelfie'] ?? false,
    );
  }
}
