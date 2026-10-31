// Exact-source offline ring and IPC-reply fixture tests; no connection/device I/O.
#include "../../macos/Runner/NakuAudioClient.c"
#include <assert.h>
#include <math.h>

static void initializeRing(NakuAudioShared *ring) {
    memset(ring, 0, sizeof(*ring));
    ring->magic = NAKU_AUDIO_MAGIC;
    ring->version = NAKU_AUDIO_ABI;
    ring->capacity = NAKU_AUDIO_CAPACITY;
    ring->sampleRate = NAKU_AUDIO_RATE;
    atomic_init(&ring->writeFrame, 0);
    atomic_init(&ring->generation, 1);
    atomic_init(&ring->writerStarts, 0);
    atomic_init(&ring->writerActive, 0);
    for (size_t i = 0; i < NAKU_AUDIO_CAPACITY*NAKU_AUDIO_CHANNELS; ++i) atomic_init(&ring->samples[i], 0);
}
static void writeFrames(NakuAudioShared *ring, uint64_t start, uint64_t end) {
    for (uint64_t f = start; f < end; ++f) {
        float samples[2] = { (float)f, -(float)f };
        for (size_t ch = 0; ch < 2; ++ch) {
            uint32_t bits; memcpy(&bits, &samples[ch], sizeof(bits));
            atomic_store_explicit(&ring->samples[(f%NAKU_AUDIO_CAPACITY)*2+ch], bits, memory_order_relaxed);
        }
    }
    atomic_store_explicit(&ring->writeFrame, end, memory_order_release);
}
int main(void) {
    NakuAudioShared *ring = calloc(1, sizeof(*ring)); assert(ring);
    initializeRing(ring);
    NAKUAudioReader reader = {0};
    atomic_init(&reader.references, 1);
    atomic_init(&reader.connected, true);
    atomic_init(&reader.closing, false);
    atomic_init(&reader.failed, false);
    atomic_init(&reader.handlerReleased, false);
    pthread_mutex_init(&reader.mutex, NULL);
    reader.shared = ring; reader.mappedSize = sizeof(*ring); reader.generation = 1;
    float out[64]; uint64_t dropped = 99;
    assert(headerValid(ring, sizeof(*ring)));
    assert(!headerValid(ring, sizeof(*ring)-1));
    assert(!headerValid(ring, sizeof(*ring)+1));
    ring->version = 9; assert(!headerValid(ring, sizeof(*ring))); ring->version = NAKU_AUDIO_ABI;
    ring->capacity = 1; assert(!headerValid(ring, sizeof(*ring))); ring->capacity = NAKU_AUDIO_CAPACITY;
    ring->sampleRate = 44100; assert(!headerValid(ring, sizeof(*ring))); ring->sampleRate = NAKU_AUDIO_RATE;
    assert(NAKUAudioReaderRead(&reader, out, 32, &dropped) == 0 && dropped == 0);
    writeFrames(ring, 0, 10);
    assert(NAKUAudioReaderRead(&reader, out, 32, &dropped) == 10 && dropped == 0);
    for (size_t f=0; f<10; ++f) { assert(out[f*2] == (float)f); assert(out[f*2+1] == -(float)f); }
    assert(NAKUAudioReaderRead(&reader, out, 32, NULL) == 0);
    writeFrames(ring, 10, 6000);
    assert(NAKUAudioReaderRead(&reader, out, 16, &dropped) == 16);
    assert(dropped == 6000 - 10 - NAKU_READER_KEEP_FRAMES);
    assert(out[0] == (float)(6000-NAKU_READER_KEEP_FRAMES));
    assert(reader.cursor == 6000-NAKU_READER_KEEP_FRAMES+16);
    // A generation change starts at current write position, not stale audio.
    atomic_store(&ring->writeFrame, 100);
    atomic_store(&ring->generation, 2);
    assert(NAKUAudioReaderRead(&reader, out, 32, &dropped) == 0 && reader.cursor == 100);
    assert(dropped == 6000 - 10 - NAKU_READER_KEEP_FRAMES);
    reader.cursor = NAKU_AUDIO_CAPACITY-2;
    atomic_store(&ring->writeFrame, reader.cursor);
    writeFrames(ring, reader.cursor, reader.cursor+4);
    assert(NAKUAudioReaderRead(&reader, out, 32, NULL) == 4);
    for(size_t f=0; f<4; ++f) assert(out[f*2] == (float)(NAKU_AUDIO_CAPACITY-2+f));
    // Producer counter reset without a generation bump also discards old timeline.
    atomic_store(&ring->writeFrame, 0);
    assert(NAKUAudioReaderRead(&reader, out, 32, NULL) == 0 && reader.cursor == 0);
    ring->magic = 0;
    assert(NAKUAudioReaderRead(&reader, out, 32, NULL) == 0 && !NAKUAudioReaderIsConnected(&reader));
    char error[128]; int code = 0;
    xpc_object_t reply = xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_bool(reply,"ok",false);
    xpc_dictionary_set_int64(reply,"errorCode",2);
    xpc_dictionary_set_string(reply,"error","Unauthorized reader");
    assert(!replyOK(reply,error,sizeof(error),&code) && code == 2 && strstr(error,"Unauthorized"));
    xpc_dictionary_set_bool(reply,"ok",true);
    assert(!replyOK(reply,error,sizeof(error),&code) && code == NAKU_ERROR_PROTOCOL);
    xpc_dictionary_set_uint64(reply,"version",NAKU_AUDIO_ABI);
    assert(replyOK(reply,error,sizeof(error),&code));
    xpc_release(reply);
    pthread_mutex_destroy(&reader.mutex); free(ring);
    puts("PASS: exact-source ring validation, reads, 96ms retention/drops, generation/counter reset, wraparound, disconnect, broker reply classification");
    return 0;
}
