#!/usr/bin/env python3
"""Exercise the native display proof transport without NAS or saved credentials."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Native Home Display fixtures require macOS and swiftc.")
    root = Path(__file__).resolve().parents[1]
    source = (root / "macos/Runner/NakuNASMovies.swift").read_text()
    core = source.replace("import FlutterMacOS", "")
    assert 'case "homeDisplayAuthorize": value=await session.homeDisplayAuthorize()' in source
    assert 'return ["authenticated":true,"expiresAt":authorized.expiresAt]' in source
    assert source.count("invalidateCredential(generation:attempt)") == 2
    assert "NASHomeDisplayCookies.shared.clear(" not in source
    invalidation = source.split("func invalidateCredential(generation attempt: Int) async {", 1)[1].split("\n}\n", 1)[0]
    assert "guard attempt >= generation else { return }" in invalidation
    assert "generation=attempt" in invalidation
    assert "let before=pending" in invalidation and "await before?.value" in invalidation
    assert "NASHomeDisplayCookiePolicy.shouldInvalidate(cookie)" in invalidation
    assert "pending=next;await next.value" in invalidation
    assert "setCookie" not in invalidation
    assert 'case "logout": await session.cancelQR(); await session.logoutAndInvalidateDisplay(); value=nil' in source
    assert 'case "forget": try await session.forget(); value=nil' in source
    assert "if let active=homeDisplayAuthorization,active.generation == generation {return active.task}" in source
    assert "func homeDisplayAuthorize() async -> [String:Any] {await homeDisplayAuthorizationTask().value}" in source
    forget = source.split("func forget() async throws {", 1)[1].split("\n    }", 1)[0]
    assert forget.index("await logoutAndInvalidateDisplay()") < forget.index("guard generation == attempt") < forget.index("credentialStore.forget()")
    with tempfile.TemporaryDirectory(prefix="naku-display-fixtures-") as temp:
        folder = Path(temp)
        path = folder / "NASMovieCore.swift"
        path.write_text(core)
        # Generate fixture material with OpenSSL; no Keychain access or real NAS
        # credentials are required by this harness.
        key = subprocess.run(["openssl", "genrsa", "2048"], capture_output=True, check=True).stdout
        public = subprocess.run(["openssl", "rsa", "-pubout"], input=key, capture_output=True, check=True).stdout
        public_path = folder / "fixture-public.pem"
        public_path.write_bytes(public)
        binary = folder / "display-fixtures"
        subprocess.run([
            "swiftc", "-module-cache-path", str(folder / "module-cache"), str(path),
            str(root / "macos/Runner/NakuNASQR.swift"),
            str(root / "test/native/nas_home_display_test.swift"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(public_path)], check=True, timeout=45)


if __name__ == "__main__":
    main()
