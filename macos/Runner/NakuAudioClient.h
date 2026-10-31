#ifndef NAKU_AUDIO_CLIENT_H
#define NAKU_AUDIO_CLIENT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct NAKUAudioReader NAKUAudioReader;
// Open and Arm block for at most five seconds. Call them off the main thread.
// No device, default-output, microphone, or permission settings are changed here.
NAKUAudioReader *NAKUAudioReaderOpen(char *error, size_t errorCapacity, int *errorCode);
// Returns 48kHz interleaved stereo Float32 frames. Nonblocking except a short
// reader-state mutex; performs no allocation or IPC. droppedFrames is cumulative.
size_t NAKUAudioReaderRead(NAKUAudioReader *reader, float *interleavedStereo,
                           size_t maxFrames, uint64_t *droppedFrames);
bool NAKUAudioReaderIsConnected(NAKUAudioReader *reader);
bool NAKUAudioReaderArm(NAKUAudioReader *reader, const char *previousOutputUID,
                        const char *previousSystemUID, char *error, size_t errorCapacity);
void NAKUAudioReaderDisarm(NAKUAudioReader *reader);
// Stop/quiesce Read callers before Close. Pending XPC replies/invalidation are
// separately retained and may finish safely after this function returns.
void NAKUAudioReaderClose(NAKUAudioReader *reader);
#ifdef __cplusplus
}
#endif
#endif
