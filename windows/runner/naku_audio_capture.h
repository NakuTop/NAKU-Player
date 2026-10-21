#pragma once
#include <windows.h>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>
#include <cstdint>

// Windows process loopback: this application only, never the microphone.
class NakuAudioCapture {
 public:
  struct Chunk { std::vector<uint8_t> pcm; bool active; HRESULT error; };
  ~NakuAudioCapture();
  void Start();
  void Stop();
  void Clear();
  Chunk Pull();
 private:
  void Run();
  std::mutex mutex_;
  std::vector<uint8_t> pcm_;
  std::thread worker_;
  HANDLE stop_ = nullptr;
  bool active_ = false;
  HRESULT error_ = S_OK;
};
