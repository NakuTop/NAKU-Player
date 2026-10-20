#pragma once

#include <windows.h>
#include <bcrypt.h>
#include <filesystem>
#include <optional>
#include <string>

// NAS wire encryption uses Windows CNG. Persisted credentials use current-user
// DPAPI, never a plaintext preferences file or a key embedded in the program.
class NakuSecureBridge {
 public:
  static std::filesystem::path DefaultPath();
  explicit NakuSecureBridge(std::filesystem::path file = DefaultPath());
  ~NakuSecureBridge();
  NakuSecureBridge(const NakuSecureBridge&) = delete;
  NakuSecureBridge& operator=(const NakuSecureBridge&) = delete;

  std::optional<std::string> Read() const;
  void Write(const std::string& value) const;
  void Delete() const;
  static std::string Seal(const std::string& text, const std::string& key);
  static std::string Open(const std::string& text, const std::string& key);
  static std::string Rsa(const std::string& text, const std::string& public_key);
  std::string QrKey();
  std::string QrDecrypt(const std::string& text) const;
  void QrClear();

 private:
  std::filesystem::path file_;
  BCRYPT_KEY_HANDLE qr_key_ = nullptr;
};
