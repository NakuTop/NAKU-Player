#include "../runner/naku_secure_bridge.h"
#include <wincrypt.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>

namespace {
void Require(bool okay) { if (!okay) throw std::runtime_error("Test assertion failed"); }
template<class Action> void Reject(Action action) {
  bool rejected = false;
  try { action(); } catch (const std::exception&) { rejected = true; }
  Require(rejected);
}
std::string B64(const std::vector<BYTE>& bytes) {
  DWORD size = 0;
  Require(CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
      CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &size));
  std::string result(size, '\0');
  Require(CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
      CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, result.data(), &size));
  result.resize(size);
  return result;
}
}
int main(int argc, char** argv) {
  try {
    Require(argc == 2);
    NakuSecureBridge bridge{std::filesystem::path(argv[1])};
    Require(!bridge.Read());
    const std::string value = u8"{\"username\":\"本机测试\",\"password\":\"fake-test-only\"}";
    bridge.Write(value);
    Require(bridge.Read() == value);
    std::ifstream stored(argv[1], std::ios::binary);
    const std::string protected_bytes((std::istreambuf_iterator<char>(stored)), {});
    stored.close();
    Require(protected_bytes.find("fake-test-only") == std::string::npos);
    bridge.Write("replacement-test-value");
    Require(bridge.Read() == "replacement-test-value");
    bridge.Delete();
    Require(!bridge.Read());
    std::cout << "PASS: DPAPI protected persistence, replacement and deletion\n";

    for (const size_t size : {16u, 24u, 32u}) {
      const std::string key(size, 'K');
      const auto sealed = NakuSecureBridge::Seal(value, key);
      Require(NakuSecureBridge::Open(sealed, key) == value);
      Require(NakuSecureBridge::Seal(value, key) != sealed);
      Reject([&] { NakuSecureBridge::Open(sealed, std::string(size, 'X')); });
      auto altered = sealed;
      altered[20] = altered[20] == 'A' ? 'B' : 'A';
      Reject([&] { NakuSecureBridge::Open(altered, key); });
      Require(NakuSecureBridge::Open(NakuSecureBridge::Seal("", key), key).empty());
    }
    Reject([] { NakuSecureBridge::Open("invalid", "invalid"); });
    std::cout << "PASS: AES-GCM 128/192/256, random nonce, tag rejection and empty payload\n";
    // NIST AES-128-GCM empty-message test: zero key/IV and published tag.
    std::vector<BYTE> nist(12, 0);
    const BYTE tag[] = {0x58,0xe2,0xfc,0xce,0xfa,0x7e,0x30,0x61,0x36,0x7f,0x1d,0x57,0xa4,0xe7,0x45,0x5a};
    nist.insert(nist.end(), std::begin(tag), std::end(tag));
    Require(NakuSecureBridge::Open(B64(nist), std::string(16, '\0')).empty());
    std::cout << "PASS: published AES-GCM known-answer vector\n";

    const auto public_key = bridge.QrKey();
    Require(public_key.find("-----BEGIN RSA PUBLIC KEY-----\n") == 0);
    const auto cipher = NakuSecureBridge::Rsa(value, public_key);
    Require(bridge.QrDecrypt(cipher) == value);
    Require(bridge.QrDecrypt(NakuSecureBridge::Rsa(value,
        B64(std::vector<BYTE>(public_key.begin(), public_key.end())))) == value);
    // Check the UGREEN wire representation is SPKI, and accept PKCS#1 too.
    DWORD size = 0;
    Require(CryptStringToBinaryA(public_key.c_str(), 0, CRYPT_STRING_BASE64HEADER,
        nullptr, &size, nullptr, nullptr));
    std::vector<BYTE> der(size);
    Require(CryptStringToBinaryA(public_key.c_str(), 0, CRYPT_STRING_BASE64HEADER,
        der.data(), &size, nullptr, nullptr));
    CERT_PUBLIC_KEY_INFO* info = nullptr;
    DWORD info_size = 0;
    Require(CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO, der.data(), size,
        CRYPT_DECODE_ALLOC_FLAG, nullptr, &info, &info_size));
    const std::vector<BYTE> pkcs1(info->PublicKey.pbData, info->PublicKey.pbData + info->PublicKey.cbData);
    LocalFree(info);
    const std::string pkcs1_pem = "-----BEGIN RSA PUBLIC KEY-----\n" + B64(pkcs1) + "\n-----END RSA PUBLIC KEY-----";
    Require(bridge.QrDecrypt(NakuSecureBridge::Rsa(value, pkcs1_pem)) == value);
    bridge.QrClear();
    Reject([&] { bridge.QrDecrypt(cipher); });
    bridge.QrKey();
    Reject([&] { bridge.QrDecrypt(cipher); });
    std::cout << "PASS: RSA SPKI/PKCS#1, base64 PEM challenge, QR decryption and key disposal\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
