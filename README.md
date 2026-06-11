# provenshot-verify

The public verification site and open verification core for
[Provenshot](https://provenshot.app) sealed photos.

- **[provenshot.app/verify](https://provenshot.app/verify)** — drop a sealed
  photo in; it verifies entirely inside your browser. Nothing is uploaded.
- **[SPEC.md](SPEC.md)** — the complete evidence format and verification
  specification: anyone can verify a Provenshot photo with standard tools,
  without this site or the app.
- **[`src/`](src/)** — the reference verifier (pure Dart). The exact same code
  runs inside the app and, compiled with `dart compile js`, on the verify page:

  ```sh
  dart pub get
  dart compile js src/verify_web.dart -o verifier.js -O2
  ```

- **[privacy/](privacy/)** — the app's privacy policy (no accounts, no
  analytics, no server that receives photos or location).

## Why open?

Provenshot's claim is "proof you can verify" — that only works if the
verification itself doesn't require trusting us. The cryptography is all
standard (SHA-256 over decoded pixels, hardware-backed ECDSA P-256), the
format is documented, and the verifier is auditable and reproducible.

Provenshot is **tamper-evident, not tamper-proof**: verification proves the
photo and its signed record are unchanged since sealing — the limits of what
it cannot prove are part of the spec (see SPEC.md §7).
