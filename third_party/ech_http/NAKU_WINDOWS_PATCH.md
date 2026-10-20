Vendored from ech_http 0.2.1 (pub.dev), under the included LICENSE.

Windows build changes: split the embedded Mozilla CA bundle into per-certificate
raw literals and append them at runtime, avoiding MSVC error C2026. The resulting
certificate bytes remain unchanged. Compile C++ sources as UTF-8 on MSVC.
