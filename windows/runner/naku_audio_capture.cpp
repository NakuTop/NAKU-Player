#include "naku_audio_capture.h"
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <wrl.h>
#include <algorithm>

using Microsoft::WRL::ComPtr;
class AudioActivation final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IActivateAudioInterfaceCompletionHandler, Microsoft::WRL::FtmBase> {
 public:
  AudioActivation() : ready(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~AudioActivation() { if (ready) CloseHandle(ready); }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* operation) override {
    ComPtr<IUnknown> unknown;
    result = operation->GetActivateResult(&activation, &unknown);
    if (SUCCEEDED(result)) result = activation;
    if (SUCCEEDED(result)) result = unknown.As(&client);
    SetEvent(ready);
    return S_OK;
  }
  HANDLE ready;
  HRESULT result = E_PENDING;
  HRESULT activation = E_PENDING;
  ComPtr<IAudioClient> client;
};

NakuAudioCapture::~NakuAudioCapture() { Stop(); }
void NakuAudioCapture::Start() {
  Stop();
  stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  { std::lock_guard<std::mutex> guard(mutex_); error_ = S_OK; pcm_.clear(); }
  worker_ = std::thread([this] { Run(); });
}
void NakuAudioCapture::Stop() {
  if (stop_) SetEvent(stop_);
  if (worker_.joinable()) worker_.join();
  if (stop_) { CloseHandle(stop_); stop_ = nullptr; }
  std::lock_guard<std::mutex> guard(mutex_);
  active_ = false;
  pcm_.clear();
}
void NakuAudioCapture::Clear() {
  std::lock_guard<std::mutex> guard(mutex_); pcm_.clear();
}
NakuAudioCapture::Chunk NakuAudioCapture::Pull() {
  std::lock_guard<std::mutex> guard(mutex_);
  Chunk chunk{{}, active_, error_};
  constexpr size_t kChunk = 16000 * 2;
  if (pcm_.size() >= kChunk) {
    // Consume pending audio together. Never let recognizer work build a FIFO
    // of old five-second chunks; late inference must catch up to playback.
    const size_t keep = (std::min)(pcm_.size(), kChunk * 2);
    chunk.pcm.assign(pcm_.end() - keep, pcm_.end());
    pcm_.clear();
  }
  return chunk;
}
void NakuAudioCapture::Run() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HRESULT result = initialized;
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  if (SUCCEEDED(initialized)) {
    result = [&]() -> HRESULT {
      auto callback = Microsoft::WRL::Make<AudioActivation>();
      if (!ready || !callback->ready || !stop_) return E_OUTOFMEMORY;
      AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
      parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
      parameters.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
      parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
      PROPVARIANT activation{};
      activation.vt = VT_BLOB;
      activation.blob.cbSize = sizeof(parameters);
      activation.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);
      ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
      HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
          __uuidof(IAudioClient), &activation, callback.Get(), &operation);
      if (FAILED(hr)) return hr;
      HANDLE activated[] = {stop_, callback->ready};
      const DWORD wait = WaitForMultipleObjects(2, activated, FALSE, 5000);
      if (wait == WAIT_OBJECT_0) return S_OK;
      if (wait != WAIT_OBJECT_0 + 1) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
      if (FAILED(callback->result)) return callback->result;
      client = callback->client;
      WAVEFORMATEX format{};
      format.wFormatTag = WAVE_FORMAT_PCM;
      format.nChannels = 1;
      format.nSamplesPerSec = 16000;
      format.wBitsPerSample = 16;
      format.nBlockAlign = 2;
      format.nAvgBytesPerSec = 32000;
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
          AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
          AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, 0, 0, &format, nullptr);
      if (FAILED(hr)) return hr;
      hr = client->SetEventHandle(ready);
      if (FAILED(hr)) return hr;
      hr = client->GetService(IID_PPV_ARGS(&capture));
      if (FAILED(hr)) return hr;
      hr = client->Start();
      if (FAILED(hr)) return hr;
      { std::lock_guard<std::mutex> guard(mutex_); active_ = true; }
      HANDLE events[] = {stop_, ready};
      while (WaitForMultipleObjects(2, events, FALSE, 100) != WAIT_OBJECT_0) {
        UINT32 packet = 0;
        hr = capture->GetNextPacketSize(&packet);
        if (FAILED(hr)) return hr;
        while (packet) {
          BYTE* data = nullptr;
          UINT32 frames = 0;
          DWORD flags = 0;
          hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
          if (FAILED(hr)) return hr;
          {
            std::lock_guard<std::mutex> guard(mutex_);
            const size_t count = static_cast<size_t>(frames) * 2;
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) pcm_.insert(pcm_.end(), count, 0);
            else if (data) pcm_.insert(pcm_.end(), data, data + count);
            constexpr size_t kMaximum = 16000 * 2 * 3;
            if (pcm_.size() > kMaximum) pcm_.erase(pcm_.begin(), pcm_.end() - kMaximum);
          }
          capture->ReleaseBuffer(frames);
          hr = capture->GetNextPacketSize(&packet);
          if (FAILED(hr)) return hr;
        }
      }
      return S_OK;
    }();
  }
  if (client) client->Stop();
  capture.Reset(); client.Reset();
  if (ready) CloseHandle(ready);
  { std::lock_guard<std::mutex> guard(mutex_); active_ = false; error_ = result; }
  if (SUCCEEDED(initialized)) CoUninitialize();
}
