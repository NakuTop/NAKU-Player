#include "naku_secure_bridge.h"

#include <wincrypt.h>
#include <shlobj.h>
#include <algorithm>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <vector>

namespace {
using Bytes = std::vector<unsigned char>;
constexpr size_t kLimit = 1024 * 1024;
void Check(bool okay) {
  if (!okay) throw std::runtime_error("NAS cryptography or protected storage failed");
}
void Status(NTSTATUS status) { Check(status >= 0); }
ULONG Size(size_t size) { Check(size <= kLimit); return static_cast<ULONG>(size); }
struct Algorithm {
  BCRYPT_ALG_HANDLE handle = nullptr;
  explicit Algorithm(LPCWSTR name) {
    Status(BCryptOpenAlgorithmProvider(&handle, name, nullptr, 0));
  }
  ~Algorithm() { if (handle) BCryptCloseAlgorithmProvider(handle, 0); }
};
struct Key {
  BCRYPT_KEY_HANDLE handle = nullptr;
  ~Key() { if (handle) BCryptDestroyKey(handle); }
};
struct LocalMemory {
  void* data = nullptr;
  ~LocalMemory() { if (data) LocalFree(data); }
};
std::string Base64(const Bytes& bytes) {
  DWORD count = 0;
  Check(CryptBinaryToStringA(bytes.data(), Size(bytes.size()),
      CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &count));
  std::string result(count, '\0');
  Check(CryptBinaryToStringA(bytes.data(), Size(bytes.size()),
      CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, result.data(), &count));
  result.resize(count);
  return result;
}
Bytes Decode(const std::string& text) {
  DWORD size = 0;
  Check(CryptStringToBinaryA(text.data(), Size(text.size()),
      CRYPT_STRING_BASE64_ANY, nullptr, &size, nullptr, nullptr));
  Bytes result(size);
  Check(CryptStringToBinaryA(text.data(), Size(text.size()),
      CRYPT_STRING_BASE64_ANY, result.data(), &size, nullptr, nullptr));
  result.resize(size);
  return result;
}
Bytes Random(size_t size) {
  Bytes result(size);
  Status(BCryptGenRandom(nullptr, result.data(), Size(size),
      BCRYPT_USE_SYSTEM_PREFERRED_RNG));
  return result;
}
Bytes Aes(const Bytes& input, const std::string& secret, Bytes& nonce,
          Bytes& tag, bool encrypt) {
  Check(secret.size() == 16 || secret.size() == 24 || secret.size() == 32);
  Check(nonce.size() == 12 && tag.size() == 16);
  Algorithm algorithm(BCRYPT_AES_ALGORITHM);
  Status(BCryptSetProperty(algorithm.handle, BCRYPT_CHAINING_MODE,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),
      sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
  Key key;
  Status(BCryptGenerateSymmetricKey(algorithm.handle, &key.handle, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<char*>(secret.data())), Size(secret.size()), 0));
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO auth;
  BCRYPT_INIT_AUTH_MODE_INFO(auth);
  auth.pbNonce = nonce.data();
  auth.cbNonce = Size(nonce.size());
  auth.pbTag = tag.data();
  auth.cbTag = Size(tag.size());
  Bytes output(input.size() + 16);
  ULONG written = 0;
  auto operation = encrypt ? BCryptEncrypt : BCryptDecrypt;
  const auto status = operation(key.handle,
      const_cast<PUCHAR>(input.data()), Size(input.size()), &auth, nullptr, 0,
      output.data(), Size(output.size()), &written, 0);
  if (status < 0) {
    SecureZeroMemory(output.data(), output.size());
    Status(status);
  }
  output.resize(written);
  return output;
}
Bytes Der(unsigned char type, Bytes bytes) {
  Bytes header{type};
  size_t size = bytes.size();
  if (size < 128) header.push_back(static_cast<unsigned char>(size));
  else {
    Bytes length;
    for (; size != 0; size >>= 8) length.insert(length.begin(), static_cast<unsigned char>(size & 255));
    header.push_back(static_cast<unsigned char>(0x80 | length.size()));
    header.insert(header.end(), length.begin(), length.end());
  }
  header.insert(header.end(), bytes.begin(), bytes.end());
  return header;
}
Bytes Integer(Bytes value) {
  while (value.size() > 1 && value.front() == 0) value.erase(value.begin());
  if (value.empty() || (value.front() & 0x80)) value.insert(value.begin(), 0);
  return Der(2, std::move(value));
}
// Accept both SubjectPublicKeyInfo (BEGIN PUBLIC KEY) and PKCS#1
// (BEGIN RSA PUBLIC KEY), including NAS base64-of-PEM challenge headers.
void ImportPublic(const std::string& text, Key& key) {
  Bytes der = Decode(text);
  if (der.size() > 10 && std::string(der.begin(), der.begin() + 10).find("-----BEGIN") == 0)
    der = Decode(std::string(der.begin(), der.end()));
  LocalMemory spki;
  DWORD size = 0;
  if (CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
      der.data(), Size(der.size()), CRYPT_DECODE_ALLOC_FLAG, nullptr, &spki.data, &size)) {
    Check(CryptImportPublicKeyInfoEx2(X509_ASN_ENCODING,
        static_cast<PCERT_PUBLIC_KEY_INFO>(spki.data), 0, nullptr, &key.handle));
    return;
  }
  LocalMemory legacy;
  Check(CryptDecodeObjectEx(X509_ASN_ENCODING, RSA_CSP_PUBLICKEYBLOB,
      der.data(), Size(der.size()), CRYPT_DECODE_ALLOC_FLAG, nullptr, &legacy.data, &size));
  Check(size >= sizeof(BLOBHEADER) + sizeof(RSAPUBKEY));
  const auto* rsa = reinterpret_cast<const RSAPUBKEY*>(
      static_cast<const BYTE*>(legacy.data) + sizeof(BLOBHEADER));
  Check(rsa->bitlen >= 2048 && rsa->bitlen <= 16384 && rsa->bitlen % 8 == 0);
  const ULONG modulus_size = rsa->bitlen / 8;
  Check(size >= sizeof(BLOBHEADER) + sizeof(RSAPUBKEY) + modulus_size);
  Bytes exponent;
  for (DWORD value = rsa->pubexp; value; value >>= 8)
    exponent.insert(exponent.begin(), static_cast<BYTE>(value & 255));
  Check(!exponent.empty());
  BCRYPT_RSAKEY_BLOB header{BCRYPT_RSAPUBLIC_MAGIC, rsa->bitlen,
      Size(exponent.size()), modulus_size, 0, 0};
  const BYTE* begin = reinterpret_cast<const BYTE*>(&header);
  Bytes blob(begin, begin + sizeof(header));
  blob.insert(blob.end(), exponent.begin(), exponent.end());
  const auto* modulus = reinterpret_cast<const BYTE*>(rsa + 1);
  for (ULONG i = modulus_size; i != 0; --i) blob.push_back(modulus[i - 1]);
  Algorithm algorithm(BCRYPT_RSA_ALGORITHM);
  Status(BCryptImportKeyPair(algorithm.handle, nullptr, BCRYPT_RSAPUBLIC_BLOB,
      &key.handle, blob.data(), Size(blob.size()), 0));
}
std::string RsaTransform(BCRYPT_KEY_HANDLE key, const Bytes& input, bool encrypt) {
  ULONG count = 0;
  auto operation = encrypt ? BCryptEncrypt : BCryptDecrypt;
  Status(operation(key, const_cast<PUCHAR>(input.data()), Size(input.size()),
      nullptr, nullptr, 0, nullptr, 0, &count, BCRYPT_PAD_PKCS1));
  Bytes output(count);
  Status(operation(key, const_cast<PUCHAR>(input.data()), Size(input.size()),
      nullptr, nullptr, 0, output.data(), Size(output.size()), &count, BCRYPT_PAD_PKCS1));
  output.resize(count);
  if (encrypt) return Base64(output);
  std::string result(output.begin(), output.end());
  SecureZeroMemory(output.data(), output.size());
  return result;
}
}  // namespace

std::filesystem::path NakuSecureBridge::DefaultPath() {
  PWSTR path = nullptr;
  Check(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &path)));
  std::filesystem::path root(path);
  CoTaskMemFree(path);
  return root / L"NakuTop" / L"NAKU Player" / L"security" / L"nas-credentials.dpapi";
}
NakuSecureBridge::NakuSecureBridge(std::filesystem::path file) : file_(std::move(file)) {}
NakuSecureBridge::~NakuSecureBridge() { QrClear(); }
std::optional<std::string> NakuSecureBridge::Read() const {
  if (!std::filesystem::exists(file_)) return std::nullopt;
  Check(std::filesystem::file_size(file_) <= kLimit);
  std::ifstream stream(file_, std::ios::binary);
  Check(stream.good());
  Bytes bytes((std::istreambuf_iterator<char>(stream)), {});
  DATA_BLOB input{Size(bytes.size()), bytes.data()}, output{};
  Check(CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
      CRYPTPROTECT_UI_FORBIDDEN, &output));
  std::string result(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return result;
}
void NakuSecureBridge::Write(const std::string& value) const {
  DATA_BLOB input{Size(value.size()), reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))}, output{};
  Check(CryptProtectData(&input, L"NAKU NAS credentials", nullptr, nullptr,
      nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output));
  LocalMemory memory;
  memory.data = output.pbData;
  std::filesystem::create_directories(file_.parent_path());
  auto temporary = file_;
  temporary += L".tmp";
  {
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    Check(stream.good());
    stream.write(reinterpret_cast<char*>(output.pbData), output.cbData);
    stream.flush();
    Check(stream.good());
  }
  Check(MoveFileExW(temporary.c_str(), file_.c_str(),
      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH));
}
void NakuSecureBridge::Delete() const { std::filesystem::remove(file_); }
std::string NakuSecureBridge::Seal(const std::string& text, const std::string& key) {
  Bytes nonce = Random(12), tag(16);
  Bytes result = Aes(Bytes(text.begin(), text.end()), key, nonce, tag, true);
  result.insert(result.begin(), nonce.begin(), nonce.end());
  result.insert(result.end(), tag.begin(), tag.end());
  return Base64(result);
}
std::string NakuSecureBridge::Open(const std::string& text, const std::string& key) {
  Bytes bytes = Decode(text);
  Check(bytes.size() >= 28);
  Bytes nonce(bytes.begin(), bytes.begin() + 12), tag(bytes.end() - 16, bytes.end());
  Bytes plain = Aes(Bytes(bytes.begin() + 12, bytes.end() - 16), key, nonce, tag, false);
  std::string result(plain.begin(), plain.end());
  SecureZeroMemory(plain.data(), plain.size());
  return result;
}
std::string NakuSecureBridge::Rsa(const std::string& text, const std::string& public_key) {
  Key key;
  ImportPublic(public_key, key);
  return RsaTransform(key.handle, Bytes(text.begin(), text.end()), true);
}
std::string NakuSecureBridge::QrKey() {
  QrClear();
  Algorithm algorithm(BCRYPT_RSA_ALGORITHM);
  Status(BCryptGenerateKeyPair(algorithm.handle, &qr_key_, 2048, 0));
  Status(BCryptFinalizeKeyPair(qr_key_, 0));
  ULONG size = 0;
  Status(BCryptExportKey(qr_key_, nullptr, BCRYPT_RSAPUBLIC_BLOB, nullptr, 0, &size, 0));
  Bytes blob(size);
  Status(BCryptExportKey(qr_key_, nullptr, BCRYPT_RSAPUBLIC_BLOB, blob.data(), size, &size, 0));
  const auto* header = reinterpret_cast<const BCRYPT_RSAKEY_BLOB*>(blob.data());
  auto exponent_start = blob.begin() + sizeof(BCRYPT_RSAKEY_BLOB);
  auto modulus_start = exponent_start + header->cbPublicExp;
  Bytes modulus = Integer(Bytes(modulus_start, modulus_start + header->cbModulus));
  Bytes exponent = Integer(Bytes(exponent_start, modulus_start));
  modulus.insert(modulus.end(), exponent.begin(), exponent.end());
  // Match the shipped UGREEN LOCAL_LOGIN wire format: SPKI DER inside an
  // RSA PUBLIC KEY PEM label (the same representation as Android/macOS).
  Bytes bits{0};
  Bytes pkcs1 = Der(0x30, std::move(modulus));
  bits.insert(bits.end(), pkcs1.begin(), pkcs1.end());
  Bytes spki{0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48,
      0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00};
  Bytes bit_string = Der(0x03, std::move(bits));
  spki.insert(spki.end(), bit_string.begin(), bit_string.end());
  std::string encoded = Base64(Der(0x30, std::move(spki)));
  std::string pem = "-----BEGIN RSA PUBLIC KEY-----\n";
  for (size_t i = 0; i < encoded.size(); i += 64) pem += encoded.substr(i, 64) + "\n";
  return pem + "-----END RSA PUBLIC KEY-----";
}
std::string NakuSecureBridge::QrDecrypt(const std::string& text) const {
  Check(qr_key_ != nullptr);
  return RsaTransform(qr_key_, Decode(text), false);
}
void NakuSecureBridge::QrClear() {
  if (qr_key_) BCryptDestroyKey(qr_key_);
  qr_key_ = nullptr;
}
