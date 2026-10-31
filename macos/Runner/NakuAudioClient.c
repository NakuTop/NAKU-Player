#include "NakuAudioClient.h"
#include "../AudioDriver/Shared/NakuAudioShared.h"
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#define NAKU_READER_KEEP_FRAMES ((uint64_t)NAKU_AUDIO_RATE * 96u / 1000u)
#define NAKU_REPLY_TIMEOUT_NS (5ull * NSEC_PER_SEC)
#define NAKU_ERROR_UNAVAILABLE 1
#define NAKU_ERROR_PROTOCOL 4
#define NAKU_ERROR_TIMEOUT 5

struct NAKUAudioReader {
    _Atomic unsigned references;
    _Atomic bool closing;
    _Atomic bool connected;
    _Atomic bool failed;
    _Atomic bool handlerReleased;
    pthread_mutex_t mutex;
    dispatch_queue_t queue;
    xpc_connection_t connection;
    NakuAudioShared *shared;
    size_t mappedSize;
    uint64_t cursor;
    uint64_t generation;
    uint64_t dropped;
};

// The waiter and callback own separate references. A timed-out waiter can leave
// without invalidating memory that an asynchronous XPC reply still references.
typedef struct {
    _Atomic unsigned references;
    dispatch_semaphore_t semaphore;
    xpc_object_t reply;
} NakuPendingReply;

static void putError(char *buffer, size_t capacity, const char *message) {
    if (buffer && capacity) snprintf(buffer, capacity, "%s", message ? message : "Audio broker unavailable");
}
static void clearError(char *buffer, size_t capacity, int *code) {
    if (buffer && capacity) buffer[0] = '\0';
    if (code) *code = 0;
}
static void unmapShared(void *address, size_t length) {
    if (address && length) (void)mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)address, (mach_vm_size_t)length);
}
static void readerRetain(NAKUAudioReader *reader) {
    atomic_fetch_add_explicit(&reader->references, 1, memory_order_relaxed);
}
static void readerRelease(NAKUAudioReader *reader) {
    if (atomic_fetch_sub_explicit(&reader->references, 1, memory_order_acq_rel) != 1) return;
    unmapShared(reader->shared, reader->mappedSize);
    if (reader->connection) xpc_release(reader->connection);
    if (reader->queue) dispatch_release(reader->queue);
    pthread_mutex_destroy(&reader->mutex);
    free(reader);
}
static void pendingRelease(NakuPendingReply *pending) {
    if (atomic_fetch_sub_explicit(&pending->references, 1, memory_order_acq_rel) != 1) return;
    if (pending->reply) xpc_release(pending->reply);
    dispatch_release(pending->semaphore);
    free(pending);
}
static bool headerValid(const NakuAudioShared *shared, size_t size) {
    const size_t minimum = sizeof(NakuAudioShared);
    const size_t page = (size_t)vm_page_size;
    const size_t maximum = page ? ((minimum + page - 1) / page) * page : minimum;
    if (!shared || (size != minimum && size != maximum)) return false;
    return shared->magic == NAKU_AUDIO_MAGIC && shared->version == NAKU_AUDIO_ABI &&
        shared->capacity == NAKU_AUDIO_CAPACITY && shared->sampleRate == NAKU_AUDIO_RATE;
}
static xpc_object_t baseRequest(const char *operation) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    if (message) {
        xpc_dictionary_set_string(message, "op", operation);
        xpc_dictionary_set_uint64(message, "version", NAKU_AUDIO_ABI);
    }
    return message;
}
static xpc_object_t requestReply(NAKUAudioReader *reader, xpc_object_t message,
                                 char *error, size_t capacity, int *code) {
    if (!reader || !message) {
        if (code) *code = NAKU_ERROR_UNAVAILABLE;
        putError(error, capacity, "Audio broker request allocation failed");
        return NULL;
    }
    readerRetain(reader);
    pthread_mutex_lock(&reader->mutex);
    xpc_connection_t connection = reader->connection;
    if (connection && !atomic_load_explicit(&reader->closing, memory_order_acquire)) xpc_retain(connection);
    else connection = NULL;
    pthread_mutex_unlock(&reader->mutex);
    if (!connection) {
        if (code) *code = NAKU_ERROR_UNAVAILABLE;
        putError(error, capacity, "Audio reader is closed");
        readerRelease(reader);
        return NULL;
    }
    NakuPendingReply *pending = calloc(1, sizeof(*pending));
    if (!pending) {
        xpc_release(connection);
        if (code) *code = NAKU_ERROR_UNAVAILABLE;
        putError(error, capacity, "Audio broker reply allocation failed");
        readerRelease(reader);
        return NULL;
    }
    atomic_init(&pending->references, 2);
    pending->semaphore = dispatch_semaphore_create(0);
    if (!pending->semaphore) {
        free(pending);
        xpc_release(connection);
        if (code) *code = NAKU_ERROR_UNAVAILABLE;
        putError(error, capacity, "Audio broker wait allocation failed");
        readerRelease(reader);
        return NULL;
    }
    xpc_connection_send_message_with_reply(connection, message,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
            pending->reply = xpc_retain(reply);
            dispatch_semaphore_signal(pending->semaphore);
            pendingRelease(pending);
        });
    long wait = dispatch_semaphore_wait(pending->semaphore,
        dispatch_time(DISPATCH_TIME_NOW, NAKU_REPLY_TIMEOUT_NS));
    xpc_object_t result = NULL;
    if (wait != 0) {
        if (code) *code = NAKU_ERROR_TIMEOUT;
        putError(error, capacity, "NAKU audio broker did not answer within five seconds");
        atomic_store_explicit(&reader->failed, true, memory_order_release);
        atomic_store_explicit(&reader->connected, false, memory_order_release);
        xpc_connection_cancel(connection);
    } else if (pending->reply && xpc_get_type(pending->reply) == XPC_TYPE_DICTIONARY) {
        result = xpc_retain(pending->reply);
    } else {
        if (code) *code = NAKU_ERROR_UNAVAILABLE;
        putError(error, capacity, "NAKU audio broker is unavailable");
        atomic_store_explicit(&reader->failed, true, memory_order_release);
        atomic_store_explicit(&reader->connected, false, memory_order_release);
    }
    pendingRelease(pending);
    xpc_release(connection);
    readerRelease(reader);
    return result;
}
static bool replyOK(xpc_object_t reply, char *error, size_t capacity, int *code) {
    if (!reply) return false;
    xpc_object_t ok = xpc_dictionary_get_value(reply, "ok");
    if (!ok || xpc_get_type(ok) != XPC_TYPE_BOOL || !xpc_bool_get_value(ok)) {
        xpc_object_t value = xpc_dictionary_get_value(reply, "errorCode");
        int number = NAKU_ERROR_UNAVAILABLE;
        if (value && xpc_get_type(value) == XPC_TYPE_INT64) number = (int)xpc_int64_get_value(value);
        else if (value && xpc_get_type(value) == XPC_TYPE_UINT64) number = (int)xpc_uint64_get_value(value);
        if (code) *code = number > 0 ? number : NAKU_ERROR_UNAVAILABLE;
        const char *message = xpc_dictionary_get_string(reply, "error");
        putError(error, capacity, message ? message : "NAKU audio broker rejected the request");
        return false;
    }
    xpc_object_t version = xpc_dictionary_get_value(reply, "version");
    if (!version || xpc_get_type(version) != XPC_TYPE_UINT64 || xpc_uint64_get_value(version) != NAKU_AUDIO_ABI) {
        if (code) *code = NAKU_ERROR_PROTOCOL;
        putError(error, capacity, "NAKU audio broker has an incompatible protocol version");
        return false;
    }
    return true;
}

NAKUAudioReader *NAKUAudioReaderOpen(char *error, size_t errorCapacity, int *errorCode) {
    clearError(error, errorCapacity, errorCode);
    NAKUAudioReader *reader = calloc(1, sizeof(*reader));
    if (!reader) {
        if (errorCode) *errorCode = NAKU_ERROR_UNAVAILABLE;
        putError(error, errorCapacity, "Audio reader allocation failed");
        return NULL;
    }
    atomic_init(&reader->references, 1);
    atomic_init(&reader->closing, false);
    atomic_init(&reader->connected, false);
    atomic_init(&reader->failed, false);
    atomic_init(&reader->handlerReleased, false);
    if (pthread_mutex_init(&reader->mutex, NULL) != 0) {
        if (errorCode) *errorCode = NAKU_ERROR_UNAVAILABLE;
        putError(error, errorCapacity, "Audio reader mutex initialization failed");
        free(reader);
        return NULL;
    }
    reader->queue = dispatch_queue_create("com.shenminghao.naku.audio-reader", DISPATCH_QUEUE_SERIAL);
    reader->connection = xpc_connection_create_mach_service(NAKU_AUDIO_SERVICE, reader->queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!reader->connection) {
        if (errorCode) *errorCode = NAKU_ERROR_UNAVAILABLE;
        putError(error, errorCapacity, "Cannot create NAKU audio broker connection");
        readerRelease(reader);
        return NULL;
    }
    readerRetain(reader); // Held until the final XPC invalidation event.
    xpc_connection_set_event_handler(reader->connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            pthread_mutex_lock(&reader->mutex);
            atomic_store_explicit(&reader->failed, true, memory_order_release);
            atomic_store_explicit(&reader->connected, false, memory_order_release);
            pthread_mutex_unlock(&reader->mutex);
            if (event == XPC_ERROR_CONNECTION_INVALID &&
                !atomic_exchange_explicit(&reader->handlerReleased, true, memory_order_acq_rel)) readerRelease(reader);
        }
    });
    xpc_connection_resume(reader->connection);
    xpc_object_t request = baseRequest("attach");
    if (request) xpc_dictionary_set_string(request, "role", "reader");
    xpc_object_t reply = requestReply(reader, request, error, errorCapacity, errorCode);
    if (request) xpc_release(request);
    bool valid = replyOK(reply, error, errorCapacity, errorCode);
    void *mapping = NULL;
    size_t mappedSize = 0;
    if (valid) {
        xpc_object_t object = xpc_dictionary_get_value(reply, "shmem");
        if (object && xpc_get_type(object) == XPC_TYPE_SHMEM) mappedSize = xpc_shmem_map(object, &mapping);
        valid = headerValid(mapping, mappedSize);
        if (!valid) {
            if (errorCode) *errorCode = NAKU_ERROR_PROTOCOL;
            putError(error, errorCapacity, "NAKU audio shared memory has an incompatible layout");
        }
    }
    if (reply) xpc_release(reply);
    if (!valid) {
        unmapShared(mapping, mappedSize);
        NAKUAudioReaderClose(reader);
        return NULL;
    }
    pthread_mutex_lock(&reader->mutex);
    if (atomic_load_explicit(&reader->failed, memory_order_acquire) ||
        atomic_load_explicit(&reader->closing, memory_order_acquire)) {
        pthread_mutex_unlock(&reader->mutex);
        unmapShared(mapping, mappedSize);
        if (errorCode) *errorCode = NAKU_ERROR_UNAVAILABLE;
        putError(error, errorCapacity, "NAKU audio broker disconnected during attachment");
        NAKUAudioReaderClose(reader);
        return NULL;
    }
    reader->shared = mapping;
    reader->mappedSize = mappedSize;
    reader->generation = atomic_load_explicit(&reader->shared->generation, memory_order_acquire);
    reader->cursor = atomic_load_explicit(&reader->shared->writeFrame, memory_order_acquire);
    atomic_store_explicit(&reader->connected, true, memory_order_release);
    pthread_mutex_unlock(&reader->mutex);
    return reader;
}

size_t NAKUAudioReaderRead(NAKUAudioReader *reader, float *output, size_t maxFrames, uint64_t *droppedFrames) {
    if (droppedFrames) *droppedFrames = 0;
    if (!reader) return 0;
    pthread_mutex_lock(&reader->mutex);
    if (droppedFrames) *droppedFrames = reader->dropped;
    NakuAudioShared *shared = reader->shared;
    if (!output || maxFrames == 0 || !atomic_load_explicit(&reader->connected, memory_order_acquire) ||
        atomic_load_explicit(&reader->closing, memory_order_acquire)) {
        pthread_mutex_unlock(&reader->mutex);
        return 0;
    }
    if (!headerValid(shared, reader->mappedSize)) {
        atomic_store_explicit(&reader->connected, false, memory_order_release);
        pthread_mutex_unlock(&reader->mutex);
        return 0;
    }
    uint64_t generation = atomic_load_explicit(&shared->generation, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&shared->writeFrame, memory_order_acquire);
    if (generation != reader->generation || write < reader->cursor) {
        reader->generation = generation;
        reader->cursor = write;
        pthread_mutex_unlock(&reader->mutex);
        return 0;
    }
    uint64_t available = write - reader->cursor;
    if (available > NAKU_READER_KEEP_FRAMES) {
        uint64_t excess = available - NAKU_READER_KEEP_FRAMES;
        reader->cursor += excess;
        reader->dropped += excess;
        available = NAKU_READER_KEEP_FRAMES;
    }
    size_t count = maxFrames < available ? maxFrames : (size_t)available;
    uint64_t start = reader->cursor;
    for (size_t frame = 0; frame < count; ++frame) {
        size_t position = (size_t)((start + frame) % NAKU_AUDIO_CAPACITY) * NAKU_AUDIO_CHANNELS;
        for (size_t channel = 0; channel < NAKU_AUDIO_CHANNELS; ++channel) {
            uint32_t bits = atomic_load_explicit(&shared->samples[position + channel], memory_order_relaxed);
            memcpy(output + frame * NAKU_AUDIO_CHANNELS + channel, &bits, sizeof(bits));
        }
    }
    uint64_t generationAfter = atomic_load_explicit(&shared->generation, memory_order_acquire);
    uint64_t writeAfter = atomic_load_explicit(&shared->writeFrame, memory_order_acquire);
    if (generationAfter != generation || writeAfter < write) {
        reader->generation = generationAfter;
        reader->cursor = writeAfter;
        count = 0;
    } else if (writeAfter - start > NAKU_AUDIO_CAPACITY) {
        uint64_t next = writeAfter > NAKU_READER_KEEP_FRAMES ? writeAfter - NAKU_READER_KEEP_FRAMES : 0;
        if (next > reader->cursor) reader->dropped += next - reader->cursor;
        reader->cursor = next;
        count = 0; // Discard a copy if a producer overrun was detected while reading.
    } else {
        reader->cursor += count;
    }
    if (droppedFrames) *droppedFrames = reader->dropped;
    pthread_mutex_unlock(&reader->mutex);
    return count;
}

bool NAKUAudioReaderIsConnected(NAKUAudioReader *reader) {
    return reader && atomic_load_explicit(&reader->connected, memory_order_acquire) &&
        !atomic_load_explicit(&reader->closing, memory_order_acquire);
}
bool NAKUAudioReaderArm(NAKUAudioReader *reader, const char *previousOutputUID,
                        const char *previousSystemUID, char *error, size_t errorCapacity) {
    clearError(error, errorCapacity, NULL);
    if (!NAKUAudioReaderIsConnected(reader)) {
        putError(error, errorCapacity, "NAKU audio reader is not connected");
        return false;
    }
    if ((previousOutputUID && strnlen(previousOutputUID, 1025) > 1024) ||
        (previousSystemUID && strnlen(previousSystemUID, 1025) > 1024)) {
        putError(error, errorCapacity, "Previous output identifier exceeds the size limit");
        return false;
    }
    xpc_object_t request = baseRequest("arm");
    if (request) {
        xpc_dictionary_set_string(request, "previousOutput", previousOutputUID ? previousOutputUID : "");
        xpc_dictionary_set_string(request, "previousSystem", previousSystemUID ? previousSystemUID : "");
    }
    int code = 0;
    xpc_object_t reply = requestReply(reader, request, error, errorCapacity, &code);
    if (request) xpc_release(request);
    bool ok = replyOK(reply, error, errorCapacity, &code);
    if (reply) xpc_release(reply);
    return ok;
}
void NAKUAudioReaderDisarm(NAKUAudioReader *reader) {
    if (!reader || atomic_load_explicit(&reader->closing, memory_order_acquire)) return;
    xpc_object_t request = baseRequest("disarm");
    xpc_object_t reply = requestReply(reader, request, NULL, 0, NULL);
    if (request) xpc_release(request);
    if (reply) xpc_release(reply);
}
void NAKUAudioReaderClose(NAKUAudioReader *reader) {
    if (!reader) return;
    atomic_store_explicit(&reader->closing, true, memory_order_release);
    atomic_store_explicit(&reader->connected, false, memory_order_release);
    pthread_mutex_lock(&reader->mutex);
    xpc_connection_t connection = reader->connection;
    reader->connection = NULL;
    void *mapping = reader->shared;
    size_t mappedSize = reader->mappedSize;
    reader->shared = NULL;
    reader->mappedSize = 0;
    pthread_mutex_unlock(&reader->mutex);
    unmapShared(mapping, mappedSize);
    if (connection) {
        xpc_connection_cancel(connection);
        xpc_release(connection);
    }
    readerRelease(reader);
}
