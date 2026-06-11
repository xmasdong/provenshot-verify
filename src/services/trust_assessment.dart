import '../models/evidence_package.dart';

/// How much the *signing key* tells us about origin.
enum KeyAssurance {
  attested, // key proven to live in genuine secure hardware (device attestation)
  hardware, // key reports secure-hardware backing (self-reported, not attested)
  software, // software key (emulator / no secure element) — anyone can make one
}

/// How much we can trust the *time*.
enum TimeAssurance {
  tsaVerified, // signed by an independent trusted timestamp authority (phase 2)
  deviceClock, // the phone's own clock — user-settable, not independently verified
}

/// An honest reading of what a verified Provenshot record does — and does NOT —
/// prove. The point is to stop "Authentic" from over-claiming: a green result
/// means the content is unchanged since sealing, not that the capture conditions
/// were independently guaranteed.
class TrustAssessment {
  final bool contentIntact; // pixels + metadata unchanged AND signature valid
  final KeyAssurance key;
  final TimeAssurance time;
  final LocationTrust location;
  final List<String> trustReasons;

  const TrustAssessment({
    required this.contentIntact,
    required this.key,
    required this.time,
    required this.location,
    required this.trustReasons,
  });

  /// [keyAttested] must be supplied by the verifier and is only true when the
  /// device attestation chain has actually been validated to a hardware root —
  /// the mere presence of a chain is NOT enough. Defaults false (v1: no chain
  /// validation yet), so the tier never over-claims.
  static TrustAssessment of(
    EvidencePackage pkg, {
    required bool contentIntact,
    bool keyAttested = false,
  }) {
    final KeyAssurance key;
    if (keyAttested) {
      key = KeyAssurance.attested;
    } else if (pkg.secureHardware) {
      key = KeyAssurance.hardware;
    } else {
      key = KeyAssurance.software;
    }
    final time =
        pkg.timeSource == 'tsa' ? TimeAssurance.tsaVerified : TimeAssurance.deviceClock;
    return TrustAssessment(
      contentIntact: contentIntact,
      key: key,
      time: time,
      location: pkg.locationTrust,
      trustReasons: pkg.trustReasons,
    );
  }

  /// One-line summary of the key's origin assurance.
  String get keyLine => switch (key) {
        KeyAssurance.attested =>
          'Signed in attested secure hardware (genuine app + device).',
        KeyAssurance.hardware =>
          'Signed by a key in this device\'s secure hardware (self-reported, '
              'not independently attested).',
        KeyAssurance.software =>
          'Signed by a software key (no secure hardware on this device) — '
              'lower assurance; anyone can generate such a key.',
      };

  String get timeLine => switch (time) {
        TimeAssurance.tsaVerified =>
          'Time confirmed by an independent timestamp authority.',
        TimeAssurance.deviceClock =>
          'Time comes from the device clock — it is NOT independently verified '
              'and could have been set by the user.',
      };

  String get locationLine => switch (location) {
        LocationTrust.suspect =>
          'Location looked spoofed at capture and was flagged.',
        LocationTrust.ok =>
          'Location passed on-device spoofing checks (mock + implausible-jump).',
        LocationTrust.unknown => 'Location trust was not determined.',
      };

  /// What a green/authentic result genuinely proves.
  List<String> get proves => [
        'The image\'s pixels are unchanged since it was sealed.',
        'Every signed field (GPS, time, address, device) is unchanged since '
            'sealing.',
        keyLine,
      ];

  /// What verification does NOT prove — stated plainly so the claim is honest.
  List<String> get limits => [
        timeLine,
        if (location == LocationTrust.suspect)
          locationLine
        else
          '$locationLine A modified app or rooted device could still feed a '
              'fake position.',
        'It does not prove the scene was real — a photo of a screen, or a '
            'staged setup, would also pass.',
        if (key == KeyAssurance.software)
          'Because the key is software-only, the signer\'s identity is not '
              'anchored to verified hardware.',
      ];

  Map<String, dynamic> toJson() => {
        'contentIntact': contentIntact,
        'key': key.name,
        'time': time.name,
        'location': location.name,
        'keyLine': keyLine,
        'timeLine': timeLine,
        'locationLine': locationLine,
        'proves': proves,
        'limits': limits,
      };
}
