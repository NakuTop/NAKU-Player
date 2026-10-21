#include "../runner/naku_audio_capture.h"
#include <sapi.h>
#include <wrl.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
  try {
    NakuAudioCapture capture;
    for (int attempt = 0; attempt < 3; ++attempt) {
      capture.Start();
      bool active = false;
      for (int i = 0; i < 100; ++i) {
        const auto chunk = capture.Pull();
        if (FAILED(chunk.error)) throw std::runtime_error("Process audio activation failed");
        if (chunk.active) { active = true; break; }
        Sleep(50);
      }
      if (!active) throw std::runtime_error("Process audio activation timeout");
      capture.Clear();
      if (argc > 1 && attempt == 0) {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        Microsoft::WRL::ComPtr<ISpVoice> voice;
        if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&voice))))
          throw std::runtime_error("Speech fixture unavailable");
        const auto speech_start = std::chrono::steady_clock::now();
        voice->Speak(L"Welcome. This is a local speech recognition test. The computer generates original subtitles while the video is playing. We can hear the words and read the captions.", SPF_ASYNC, nullptr);
        NakuAudioCapture::Chunk chunk;
        std::vector<uint8_t> collected;
        for (int i = 0; i < 200; ++i) {
          Sleep(50); chunk = capture.Pull();
          if (!chunk.pcm.empty() && collected.empty()) {
            std::cout << "First capture chunk ms: " << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-speech_start).count() << "\n";
          }
          collected.insert(collected.end(), chunk.pcm.begin(), chunk.pcm.end());
          if (collected.size() >= 160000) break;
        }
        chunk.pcm = std::move(collected);
        voice->Speak(L"", SPF_PURGEBEFORESPEAK, nullptr);
        voice.Reset(); CoUninitialize();
        if (chunk.pcm.empty()) throw std::runtime_error("No audio captured from this process");
        std::ofstream file(argv[1], std::ios::binary);
        const uint32_t size = static_cast<uint32_t>(chunk.pcm.size());
        const uint32_t riff = size + 36, fmt = 16, rate = 16000, average = 32000;
        const uint16_t pcm = 1, mono = 1, align = 2, bits = 16;
        file.write("RIFF",4).write(reinterpret_cast<const char*>(&riff),4).write("WAVEfmt ",8);
        file.write(reinterpret_cast<const char*>(&fmt),4).write(reinterpret_cast<const char*>(&pcm),2);
        file.write(reinterpret_cast<const char*>(&mono),2).write(reinterpret_cast<const char*>(&rate),4);
        file.write(reinterpret_cast<const char*>(&average),4).write(reinterpret_cast<const char*>(&align),2);
        file.write(reinterpret_cast<const char*>(&bits),2).write("data",4).write(reinterpret_cast<const char*>(&size),4);
        file.write(reinterpret_cast<const char*>(chunk.pcm.data()),size);
        std::cout << "Own-process PCM bytes: " << size << "\n";
      }
      capture.Stop();
      if (capture.Pull().active) throw std::runtime_error("Capture did not stop");
    }
    std::cout << "Process audio lifecycle passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\n"; return 1; }
}
