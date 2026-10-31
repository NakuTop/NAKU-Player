#ifndef NAKU_AUDIO_SHARED_H
#define NAKU_AUDIO_SHARED_H
#include <stdint.h>
#include <stdatomic.h>

#define NAKU_AUDIO_MAGIC 0x4E414B55u
#define NAKU_AUDIO_ABI 1u
#define NAKU_AUDIO_CAPACITY 32768u
#define NAKU_AUDIO_RATE 48000u
#define NAKU_AUDIO_CHANNELS 2u
#define NAKU_AUDIO_SERVICE "com.shenminghao.naku.audio-broker"
#define NAKU_AUDIO_DEVICE_UID "com.shenminghao.naku.virtualaudio.v1"
#define NAKU_AUDIO_APP_ID "com.shenminghao.yingchuan"
#define NAKU_AUDIO_WRITER_REQUIREMENT "(identifier \"com.apple.audio.coreaudiod\" or identifier \"com.apple.audio.DriverHelper\" or identifier \"com.apple.audio.Core-Audio-Driver-Service.helper\") and anchor apple"

// One producer, one authorized consumer. Atomic sample bits also make a
// concurrent overrun safe; no audio is written to a file or a physical input.
typedef struct {
  uint32_t magic, version, capacity, sampleRate;
  _Atomic uint64_t writeFrame;
  _Atomic uint64_t generation;
  _Atomic uint64_t writerStarts;
  _Atomic uint64_t writerActive;
  _Atomic uint32_t samples[NAKU_AUDIO_CAPACITY * NAKU_AUDIO_CHANNELS];
} NakuAudioShared;

#endif
