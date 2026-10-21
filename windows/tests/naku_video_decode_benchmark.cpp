// Optional self-generated 1080p H.264 decoder smoke/CPU benchmark. No user media.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl.h>
#include <iostream>
#include <string>
#include <vector>
#include <stdexcept>
#include <chrono>
#include <cstdint>
using Microsoft::WRL::ComPtr;
void Check(HRESULT result) { if (FAILED(result)) throw std::runtime_error("Media Foundation encoding failed"); }
void Generate(const wchar_t* path) {
  Check(MFStartup(MF_VERSION));
  ComPtr<IMFSinkWriter> writer;
  Check(MFCreateSinkWriterFromURL(path, nullptr, nullptr, &writer));
  ComPtr<IMFMediaType> output, input;
  Check(MFCreateMediaType(&output));
  output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  output->SetUINT32(MF_MT_AVG_BITRATE, 6000000);
  output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, 1920, 1080);
  MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, 24, 1);
  MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  DWORD stream = 0; Check(writer->AddStream(output.Get(), &stream));
  Check(MFCreateMediaType(&input));
  input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, 1920, 1080);
  MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, 24, 1);
  MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  Check(writer->SetInputMediaType(stream, input.Get(), nullptr)); Check(writer->BeginWriting());
  for (int frame = 0; frame < 72; ++frame) {
    ComPtr<IMFMediaBuffer> buffer; ComPtr<IMFSample> sample;
    Check(MFCreateMemoryBuffer(1920 * 1080 * 4, &buffer));
    BYTE* data; Check(buffer->Lock(&data, nullptr, nullptr));
    auto* pixels = reinterpret_cast<uint32_t*>(data);
    for (int y = 0; y < 1080; ++y) for (int x = 0; x < 1920; ++x)
      pixels[y * 1920 + x] = static_cast<uint32_t>(((x + frame * 8) % 256) | ((y % 256) << 8) | (((x + y) % 256) << 16));
    buffer->Unlock(); buffer->SetCurrentLength(1920 * 1080 * 4);
    Check(MFCreateSample(&sample)); sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(frame * 10000000LL / 24); sample->SetSampleDuration(10000000LL / 24);
    Check(writer->WriteSample(stream, sample.Get()));
  }
  Check(writer->Finalize()); writer.Reset(); MFShutdown();
}
uint64_t Cpu() {
  FILETIME created, exited, kernel, user;
  GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user);
  ULARGE_INTEGER k{}, u{}; k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
  u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
  return k.QuadPart + u.QuadPart;
}
int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  try {
    Generate(argv[2]);
    HMODULE dll = LoadLibraryW(argv[1]); if (!dll) throw std::runtime_error("libmpv not found");
    auto create = reinterpret_cast<void*(*)()>(GetProcAddress(dll, "mpv_create"));
    auto option = reinterpret_cast<int(*)(void*,const char*,const char*)>(GetProcAddress(dll, "mpv_set_option_string"));
    auto initialize = reinterpret_cast<int(*)(void*)>(GetProcAddress(dll, "mpv_initialize"));
    auto command = reinterpret_cast<int(*)(void*,const char**)>(GetProcAddress(dll, "mpv_command"));
    auto property = reinterpret_cast<char*(*)(void*,const char*)>(GetProcAddress(dll, "mpv_get_property_string"));
    auto release = reinterpret_cast<void(*)(void*)>(GetProcAddress(dll, "mpv_free"));
    auto destroy = reinterpret_cast<void(*)(void*)>(GetProcAddress(dll, "mpv_terminate_destroy"));
    const int length = WideCharToMultiByte(CP_UTF8,0,argv[2],-1,nullptr,0,nullptr,nullptr);
    std::string path(static_cast<size_t>(length), '\0'); WideCharToMultiByte(CP_UTF8,0,argv[2],-1,path.data(),length,nullptr,nullptr);
    for (const char* decoder : {"no", "d3d11va,auto"}) {
      HWND window = CreateWindowExW(0,L"STATIC",L"NAKU decoder benchmark",WS_POPUP,0,0,640,360,nullptr,nullptr,GetModuleHandle(nullptr),nullptr);
      void* player = create();
      option(player,"wid",std::to_string(reinterpret_cast<uintptr_t>(window)).c_str());
      option(player,"vo","gpu-next"); option(player,"gpu-api","d3d11"); option(player,"gpu-context","d3d11");
      option(player,"hwdec",decoder); option(player,"vd-lavc-threads","4"); option(player,"aid","no"); option(player,"idle","yes");
      option(player,"terminal","no");
      option(player,"keep-open","yes");
      if (initialize(player) < 0) throw std::runtime_error("mpv init failed");
      auto get = [&](const char* key) { char* value = property(player,key); std::string text = value ? value : "unavailable"; if (value) release(value); return text; };
      const uint64_t before = Cpu();
      const auto watch = std::chrono::steady_clock::now();
      const char* load[] = {"loadfile",path.c_str(),nullptr}; command(player,load);
      std::string actual;
      for (int i = 0; i < 400; ++i) {
        MSG message; while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) DispatchMessageW(&message);
        Sleep(10);
        const auto current = get("hwdec-current");
        if (current != "unavailable" && (current != "no" || actual.empty())) actual = current;
        if (i > 50 && get("eof-reached") == "yes") break;
      }
      const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now()-watch).count();
      std::cout << "requested=" << decoder << " actual=" << actual << " dropped=" << get("decoder-frame-drop-count")
          << " cpu_core_percent=" << (Cpu()-before)/10000000.0/seconds*100 << " wall_seconds=" << seconds << "\n";
      destroy(player); DestroyWindow(window);
    }
    FreeLibrary(dll); CoUninitialize(); return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\n"; CoUninitialize(); return 1; }
}
