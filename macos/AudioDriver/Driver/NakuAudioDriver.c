// NAKU output-only HAL driver. Independently implemented against Apple's
// AudioServerPlugIn.h interface; no microphone, input stream or capture API.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <unistd.h>
#include "../Shared/NakuAudioShared.h"

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
               "Realtime shared samples require lock-free atomics");

enum { NakuDevice = 2, NakuStream = 3, NakuVolume = 4, NakuMute = 5,
       TimestampPeriod = 16384, MaximumClients = 256, HardwareBufferFrames = 512 };
static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static const AudioServerPlugInDriverRef gDriver = &gInterfacePointer;
static AudioServerPlugInHostRef gHost;
static _Atomic uint32_t gReferences = 1, gRunning = 0, gStreamActive = 1;
static _Atomic uint32_t gVolumeBits = 0x3f800000, gMuted = 0;
static _Atomic uint64_t gAnchor = 0, gSeed = 1;
static _Atomic(NakuAudioShared *) gShared = NULL;
static _Atomic uint32_t gSharedReaders = 0;
static long double gTicksPerFrame;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static struct { UInt32 id; bool used, running; } gClients[MaximumClients];
static dispatch_queue_t gControl;
static dispatch_source_t gRetry;
static xpc_connection_t gConnection;
static bool gAttachInFlight;
static size_t gMappingSize;

static bool validDriver(AudioServerPlugInDriverRef driver) { return driver == gDriver; }
static bool validObject(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || object == NakuDevice ||
           object == NakuStream || object == NakuVolume || object == NakuMute;
}
static bool globalMain(const AudioObjectPropertyAddress *a) {
    return a && a->mScope == kAudioObjectPropertyScopeGlobal && a->mElement == kAudioObjectPropertyElementMain;
}
static bool outputMain(const AudioObjectPropertyAddress *a) {
    return a && a->mScope == kAudioObjectPropertyScopeOutput && a->mElement == kAudioObjectPropertyElementMain;
}
static bool directionalMain(const AudioObjectPropertyAddress *a) {
    return a && (a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeOutput)
           && a->mElement == kAudioObjectPropertyElementMain;
}
static AudioStreamBasicDescription streamFormat(void) {
    return (AudioStreamBasicDescription){ .mSampleRate = NAKU_AUDIO_RATE,
        .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2, .mBitsPerChannel = 32 };
}
static bool sameFormat(const AudioStreamBasicDescription *f) {
    AudioStreamBasicDescription expected = streamFormat();
    return f && f->mSampleRate == expected.mSampleRate && f->mFormatID == expected.mFormatID &&
        f->mFormatFlags == expected.mFormatFlags && f->mBytesPerPacket == 8 && f->mFramesPerPacket == 1 &&
        f->mBytesPerFrame == 8 && f->mChannelsPerFrame == 2 && f->mBitsPerChannel == 32;
}
static void notify(AudioObjectID object, AudioObjectPropertySelector selector,
                   AudioObjectPropertyScope scope) {
    if (!gHost) return;
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    gHost->PropertiesChanged(gHost, object, 1, &a);
}
static void notifyRunning(void) { notify(NakuDevice, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal); }

// The reader count protects a mapped address during broker reconnect. Only the
// non-realtime control queue waits/unmaps. Audio IO only uses lock-free atomics.
static NakuAudioShared *borrowShared(void) {
    atomic_fetch_add_explicit(&gSharedReaders, 1, memory_order_seq_cst);
    return atomic_load_explicit(&gShared, memory_order_seq_cst);
}
static void returnShared(void) { atomic_fetch_sub_explicit(&gSharedReaders, 1, memory_order_seq_cst); }
static void publishMapping(NakuAudioShared *map, size_t size) {
    pthread_mutex_lock(&gStateLock);
    NakuAudioShared *old = atomic_exchange_explicit(&gShared, NULL, memory_order_seq_cst);
    while (atomic_load_explicit(&gSharedReaders, memory_order_seq_cst) != 0) usleep(1000);
    if (old) atomic_store_explicit(&old->writerActive, 0, memory_order_release);
    if (old && gMappingSize) munmap(old, gMappingSize);
    gMappingSize = size;
    if (map) {
        atomic_store_explicit(&map->writerActive, atomic_load_explicit(&gRunning, memory_order_acquire), memory_order_release);
        atomic_fetch_add_explicit(&map->generation, 1, memory_order_release);
    }
    atomic_store_explicit(&gShared, map, memory_order_seq_cst);
    pthread_mutex_unlock(&gStateLock);
}
static void attachBroker(void);
static void createConnection(void) {
    if (gConnection) return;
    gConnection = xpc_connection_create_mach_service(NAKU_AUDIO_SERVICE, gControl,
                                                    XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    xpc_connection_t connection = gConnection;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_ERROR || connection != gConnection) return;
        gAttachInFlight = false;
        publishMapping(NULL, 0);
        if (event == XPC_ERROR_CONNECTION_INVALID) {
            xpc_connection_cancel(connection);
            xpc_release(connection);
            gConnection = NULL;
        }
    });
    xpc_connection_resume(connection);
}
static void attachBroker(void) {
    if (atomic_load_explicit(&gShared, memory_order_acquire) || gAttachInFlight) return;
    createConnection();
    if (!gConnection) return;
    gAttachInFlight = true;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", "attach");
    xpc_dictionary_set_string(request, "role", "writer");
    xpc_dictionary_set_uint64(request, "version", NAKU_AUDIO_ABI);
    xpc_connection_t requestedConnection = gConnection;
    xpc_connection_send_message_with_reply(gConnection, request, gControl, ^(xpc_object_t reply) {
        if (requestedConnection != gConnection) return;
        gAttachInFlight = false;
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
            !xpc_dictionary_get_bool(reply, "ok") ||
            xpc_dictionary_get_uint64(reply, "version") != NAKU_AUDIO_ABI) return;
        xpc_object_t shared = xpc_dictionary_get_value(reply, "shmem");
        if (!shared || xpc_get_type(shared) != XPC_TYPE_SHMEM) return;
        void *address = NULL;
        size_t size = xpc_shmem_map(shared, &address);
        if (!address) return;
        NakuAudioShared *map = address;
        if (size < sizeof(*map) || map->magic != NAKU_AUDIO_MAGIC || map->version != NAKU_AUDIO_ABI ||
            map->capacity != NAKU_AUDIO_CAPACITY || map->sampleRate != NAKU_AUDIO_RATE) {
            munmap(address, size); return;
        }
        publishMapping(map, size);
    });
    xpc_release(request);
}
static void retryBroker(void *unused) { (void)unused; attachBroker(); }

static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (driver != gDriver) return E_NOINTERFACE;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    bool supported = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!supported) return E_NOINTERFACE;
    atomic_fetch_add_explicit(&gReferences, 1, memory_order_relaxed);
    *out = gDriver;
    return S_OK;
}
static ULONG AddRef(void *driver) {
    return driver == gDriver ? atomic_fetch_add_explicit(&gReferences, 1, memory_order_relaxed) + 1 : 0;
}
static ULONG Release(void *driver) {
    if (driver != gDriver) return 0;
    uint32_t refs = atomic_load_explicit(&gReferences, memory_order_relaxed);
    while (refs > 1 && !atomic_compare_exchange_weak_explicit(&gReferences, &refs, refs - 1,
                                                            memory_order_relaxed, memory_order_relaxed)) {}
    return refs > 1 ? refs - 1 : 1; // Static singleton, never freed by a client.
}
static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!validDriver(driver) || !host) return kAudioHardwareIllegalOperationError;
    gHost = host;
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    gTicksPerFrame = (1000000000.0L * base.denom / base.numer) / NAKU_AUDIO_RATE;
    atomic_store_explicit(&gAnchor, mach_absolute_time(), memory_order_release);
#ifndef NAKU_AUDIO_DRIVER_TEST
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gControl = dispatch_queue_create("com.shenminghao.naku.audio-driver.broker", DISPATCH_QUEUE_SERIAL);
        gRetry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gControl);
        dispatch_source_set_timer(gRetry, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_MSEC * 100);
        dispatch_source_set_event_handler_f(gRetry, retryBroker);
        dispatch_resume(gRetry);
    });
#endif
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                             const AudioServerPlugInClientInfo *client, AudioObjectID *out) {
    (void)desc; (void)client; if (out) *out = kAudioObjectUnknown;
    return validDriver(d) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    return validDriver(d) && id == NakuDevice ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadDeviceError;
}
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                const AudioServerPlugInClientInfo *info) {
    if (!validDriver(d) || id != NakuDevice || !info) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateLock);
    int empty = -1;
    for (int i=0;i<MaximumClients;i++) {
        if (gClients[i].used && gClients[i].id == info->mClientID) { pthread_mutex_unlock(&gStateLock); return noErr; }
        if (!gClients[i].used && empty < 0) empty = i;
    }
    if (empty >= 0) { gClients[empty].used = true; gClients[empty].id = info->mClientID; gClients[empty].running = false; }
    pthread_mutex_unlock(&gStateLock);
    return empty >= 0 ? noErr : kAudioHardwareIllegalOperationError;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                   const AudioServerPlugInClientInfo *info) {
    if (!validDriver(d) || id != NakuDevice || !info) return kAudioHardwareBadDeviceError;
    StopIO(d, id, info->mClientID);
    pthread_mutex_lock(&gStateLock);
    for (int i=0;i<MaximumClients;i++) if (gClients[i].used && gClients[i].id == info->mClientID) gClients[i].used = false;
    pthread_mutex_unlock(&gStateLock);
    return noErr;
}
static OSStatus ConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)action; (void)info;
    return validDriver(d) && id == NakuDevice ? noErr : kAudioHardwareBadDeviceError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                            const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (!validDriver(d) || !validObject(object) || !a) return false;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner: case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
            return globalMain(a);
    }
    if (object == kAudioObjectPlugInObject) {
        if (!globalMain(a)) return false;
        switch (a->mSelector) {
            case kAudioPlugInPropertyBundleID: case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyClockDeviceList: case kAudioPlugInPropertyResourceBundle: return true;
            default: return false;
        }
    }
    if (object == NakuDevice) {
        switch (a->mSelector) {
            case kAudioDevicePropertyStreams: case kAudioDevicePropertyStreamConfiguration:
                return (globalMain(a) || directionalMain(a));
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                return directionalMain(a);
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout: return outputMain(a);
            case kAudioObjectPropertyControlList: case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyClockAlgorithm: case kAudioDevicePropertyClockIsStable:
            case kAudioDevicePropertyBufferFrameSize: case kAudioDevicePropertyBufferFrameSizeRange:
                return globalMain(a);
            default: return false;
        }
    }
    if (object == NakuStream) {
        if (!globalMain(a)) return false;
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: return true;
            default: return false;
        }
    }
    if (!globalMain(a)) return false;
    switch (a->mSelector) {
        case kAudioControlPropertyScope: case kAudioControlPropertyElement: return true;
        case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange: case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: return object == NakuVolume;
        case kAudioBooleanControlPropertyValue: return object == NakuMute;
        default: return false;
    }
}
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!out) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d,id,pid,a)) return kAudioHardwareUnknownPropertyError;
    *out = (id == NakuStream && (a->mSelector == kAudioStreamPropertyIsActive ||
        a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) ||
        (id == NakuDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) ||
        (id == NakuVolume && (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue)) ||
        (id == NakuMute && a->mSelector == kAudioBooleanControlPropertyValue);
    return noErr;
}
static UInt32 ownedObjects(AudioObjectID id, UInt32 qualifierSize, const void *qualifier, AudioObjectID *out) {
    const AudioObjectID candidates[3] = { id == kAudioObjectPlugInObject ? NakuDevice : NakuStream, NakuVolume, NakuMute };
    const UInt32 count = id == kAudioObjectPlugInObject ? 1 : id == NakuDevice ? 3 : 0;
    UInt32 included = 0;
    for (UInt32 i=0;i<count;i++) {
        bool matches = !qualifierSize;
        for (UInt32 offset=0;offset<qualifierSize;offset+=sizeof(AudioClassID)) {
            AudioClassID c;memcpy(&c,(const char*)qualifier+offset,sizeof(c));
            matches |= c == kAudioObjectClassID ||
                (candidates[i] == NakuDevice && c == kAudioDeviceClassID) ||
                (candidates[i] == NakuStream && c == kAudioStreamClassID) ||
                (candidates[i] == NakuVolume && (c == kAudioVolumeControlClassID || c == kAudioLevelControlClassID || c == kAudioControlClassID)) ||
                (candidates[i] == NakuMute && (c == kAudioMuteControlClassID || c == kAudioBooleanControlClassID || c == kAudioControlClassID));
        }
        if (matches) out[included++] = candidates[i];
    }
    return included;
}
static UInt32 listSize(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 qualifierSize,
                        const void *qualifier) {
    if (a->mSelector == kAudioObjectPropertyOwnedObjects) {
        AudioObjectID objects[3];return ownedObjects(id,qualifierSize,qualifier,objects)*sizeof(AudioObjectID);
    }
    switch (a->mSelector) {
        case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyClockDeviceList: return 0;
        case kAudioObjectPropertyControlList: return 2 * sizeof(AudioObjectID);
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: return sizeof(AudioObjectID);
        case kAudioDevicePropertyStreams: return a->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioObjectID);
        default: return UINT32_MAX;
    }
}
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid,
                                    const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *out) {
    if (!out) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d,id,pid,a)) return validObject(id) ? kAudioHardwareUnknownPropertyError : kAudioHardwareBadObjectError;
    if (a->mSelector == kAudioObjectPropertyOwnedObjects && (qs % sizeof(AudioClassID) || (qs && !q)))
        return kAudioHardwareBadPropertySizeError;
    UInt32 list = listSize(id,a,qs,q);
    if (list != UINT32_MAX) { *out = list; return noErr; }
    switch (a->mSelector) {
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyBundleID: case kAudioPlugInPropertyResourceBundle:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: *out = sizeof(CFStringRef); break;
        case kAudioDevicePropertyStreamConfiguration:
            *out = offsetof(AudioBufferList,mBuffers) + (a->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioBuffer)); break;
        case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); break;
        case kAudioDevicePropertyPreferredChannelLayout: *out = offsetof(AudioChannelLayout,mChannelDescriptions); break;
        case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); break;
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioLevelControlPropertyDecibelRange: *out = sizeof(AudioValueRange); break;
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyVirtualFormat: *out = sizeof(AudioStreamBasicDescription); break;
        case kAudioStreamPropertyAvailablePhysicalFormats: case kAudioStreamPropertyAvailableVirtualFormats:
            *out = sizeof(AudioStreamRangedDescription); break;
        case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels: case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *out = sizeof(Float32); break;
        default: *out = sizeof(UInt32); break;
    }
    return noErr;
}
static Float32 readGain(void) {
    uint32_t bits = atomic_load_explicit(&gVolumeBits,memory_order_relaxed);
    Float32 value; memcpy(&value,&bits,sizeof(value)); return value;
}
static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                                UInt32 size, UInt32 *used, void *out) {
    if (!used) return kAudioHardwareIllegalOperationError;
    UInt32 required;
    OSStatus status = GetPropertyDataSize(d,id,pid,a,qs,q,&required);
    if (status != noErr) return status;
    *used = 0;
    if (required && (!out || size < required)) return kAudioHardwareBadPropertySizeError;
    if (!required) return noErr;
    *used = required;
    UInt32 word = 0; Float64 rate = NAKU_AUDIO_RATE;
    CFStringRef text = NULL;
    AudioObjectID objects[3] = {0};
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            word = (id == NakuVolume) ? kAudioLevelControlClassID : (id == NakuMute ? kAudioBooleanControlClassID : kAudioObjectClassID); break;
        case kAudioObjectPropertyClass:
            word = id == kAudioObjectPlugInObject ? kAudioPlugInClassID : id == NakuDevice ? kAudioDeviceClassID :
                id == NakuStream ? kAudioStreamClassID : id == NakuVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID; break;
        case kAudioObjectPropertyOwner: word = id == kAudioObjectPlugInObject ? kAudioObjectUnknown : id == NakuDevice ? kAudioObjectPlugInObject : NakuDevice; break;
        case kAudioObjectPropertyName: text = id == kAudioObjectPlugInObject ? CFSTR("NAKU Audio Driver") : id == NakuDevice ? CFSTR("NAKU Audio") :
            id == NakuStream ? CFSTR("NAKU Stereo Output") : id == NakuVolume ? CFSTR("NAKU Volume") : CFSTR("NAKU Mute"); break;
        case kAudioObjectPropertyManufacturer: text = CFSTR("NAKU"); break;
        case kAudioPlugInPropertyBundleID: text = CFSTR("com.shenminghao.naku.audio-driver"); break;
        case kAudioPlugInPropertyResourceBundle: text = CFSTR(""); break;
        case kAudioDevicePropertyDeviceUID: text = CFSTR(NAKU_AUDIO_DEVICE_UID); break;
        case kAudioDevicePropertyModelUID: text = CFSTR("com.shenminghao.naku.virtualaudio.model.v1"); break;
        case kAudioObjectPropertyOwnedObjects:
            ownedObjects(id,qs,q,objects);memcpy(out,objects,required);return noErr;
        case kAudioObjectPropertyControlList: objects[0]=NakuVolume;objects[1]=NakuMute;memcpy(out,objects,required);return noErr;
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: word=NakuDevice;break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qs != sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid;memcpy(&uid,q,sizeof(uid));
            if (!uid || CFGetTypeID(uid) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
            word=CFEqual(uid,CFSTR(NAKU_AUDIO_DEVICE_UID)) ? NakuDevice : kAudioObjectUnknown;break;
        }
        case kAudioDevicePropertyTransportType: word=kAudioDeviceTransportTypeVirtual;break;
        case kAudioDevicePropertyClockDomain: word=0;break;
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyClockIsStable: word=1;break;
        case kAudioDevicePropertyDeviceIsRunning: word=atomic_load_explicit(&gRunning,memory_order_acquire)>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            word=a->mScope == kAudioObjectPropertyScopeOutput;break;
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyIsHidden: word=0;break;
        case kAudioDevicePropertyStreams: word=NakuStream;break;
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList *list=out;memset(out,0,required);
            list->mNumberBuffers=a->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
            if (list->mNumberBuffers) list->mBuffers[0].mNumberChannels=2;
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 channels[2]={1,2};memcpy(out,channels,sizeof(channels));return noErr; }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout *layout=out;memset(out,0,required);layout->mChannelLayoutTag=kAudioChannelLayoutTag_Stereo;return noErr;
        }
        case kAudioDevicePropertyNominalSampleRate: memcpy(out,&rate,sizeof(rate));return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: { AudioValueRange range={rate,rate};memcpy(out,&range,sizeof(range));return noErr; }
        case kAudioDevicePropertyBufferFrameSize: word=HardwareBufferFrames;break;
        case kAudioDevicePropertyBufferFrameSizeRange: { AudioValueRange range={HardwareBufferFrames,HardwareBufferFrames};memcpy(out,&range,sizeof(range));return noErr; }
        case kAudioDevicePropertyZeroTimeStampPeriod: word=TimestampPeriod;break;
        case kAudioDevicePropertyClockAlgorithm: word=kAudioDeviceClockAlgorithmRaw;break;
        case kAudioStreamPropertyIsActive: word=atomic_load_explicit(&gStreamActive,memory_order_relaxed);break;
        case kAudioStreamPropertyDirection: word=0;break;
        case kAudioStreamPropertyTerminalType: word=kAudioStreamTerminalTypeSpeaker;break;
        case kAudioStreamPropertyStartingChannel: word=1;break;
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyVirtualFormat: { AudioStreamBasicDescription f=streamFormat();memcpy(out,&f,sizeof(f));return noErr; }
        case kAudioStreamPropertyAvailablePhysicalFormats: case kAudioStreamPropertyAvailableVirtualFormats: {
            AudioStreamRangedDescription format={streamFormat(),{NAKU_AUDIO_RATE,NAKU_AUDIO_RATE}};memcpy(out,&format,sizeof(format));return noErr;
        }
        case kAudioControlPropertyScope: word=kAudioObjectPropertyScopeOutput;break;
        case kAudioControlPropertyElement: word=kAudioObjectPropertyElementMain;break;
        case kAudioLevelControlPropertyScalarValue: { Float32 value=readGain();memcpy(out,&value,sizeof(value));return noErr; }
        case kAudioLevelControlPropertyDecibelValue: { Float32 value=readGain();value=value>0?fmaxf(-96,20*log10f(value)):-96;memcpy(out,&value,sizeof(value));return noErr; }
        case kAudioLevelControlPropertyDecibelRange: { AudioValueRange range={-96,0};memcpy(out,&range,sizeof(range));return noErr; }
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            Float32 value;memcpy(&value,out,sizeof(value));value=fminf(1,fmaxf(0,value));value=value>0?fmaxf(-96,20*log10f(value)):-96;memcpy(out,&value,sizeof(value));return noErr;
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            Float32 value;memcpy(&value,out,sizeof(value));value=value<=-96?0:powf(10,fminf(0,value)/20);memcpy(out,&value,sizeof(value));return noErr;
        }
        case kAudioBooleanControlPropertyValue: word=atomic_load_explicit(&gMuted,memory_order_relaxed);break;
        default: return kAudioHardwareUnknownPropertyError;
    }
    if (text) { CFRetain(text);memcpy(out,&text,sizeof(text)); }
    else memcpy(out,&word,sizeof(word));
    return noErr;
}
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                                UInt32 size, const void *data) {
    (void)qs;(void)q;Boolean settable=false;
    OSStatus status=IsPropertySettable(d,id,pid,a,&settable);
    if (status != noErr) return status;
    if (!settable) return kAudioHardwareUnsupportedOperationError;
    if (!data) return kAudioHardwareBadPropertySizeError;
    if (id == NakuDevice) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 rate;memcpy(&rate,data,sizeof(rate));return rate == NAKU_AUDIO_RATE ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (id == NakuStream && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        return sameFormat(data) ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (id == NakuVolume) {
        if (size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value;memcpy(&value,data,sizeof(value));if (!isfinite(value)) return kAudioHardwareIllegalOperationError;
        if (a->mSelector == kAudioLevelControlPropertyDecibelValue) value=value<=-96?0:powf(10,fminf(0,value)/20);
        value=fminf(1,fmaxf(0,value));uint32_t bits;memcpy(&bits,&value,sizeof(bits));
        atomic_store_explicit(&gVolumeBits,bits,memory_order_relaxed);
        notify(NakuVolume,kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal);
        notify(NakuVolume,kAudioLevelControlPropertyDecibelValue,kAudioObjectPropertyScopeGlobal);
        return noErr;
    }
    if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
    UInt32 value;memcpy(&value,data,sizeof(value));if (value>1) return kAudioHardwareIllegalOperationError;
    if (id == NakuStream) atomic_store_explicit(&gStreamActive,value,memory_order_relaxed);
    else atomic_store_explicit(&gMuted,value,memory_order_relaxed);
    notify(id,a->mSelector,kAudioObjectPropertyScopeGlobal);
    return noErr;
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (!validDriver(d) || id != NakuDevice) return kAudioHardwareBadDeviceError;
    // StartIO is a non-realtime lifecycle call. A cold broker may acknowledge
    // its writer just before the shared-memory reply reaches this control queue.
    // Do not hold gStateLock here: publishing the mapping needs that lock.
    for (unsigned attempt=0; attempt<1000 &&
         !atomic_load_explicit(&gShared,memory_order_acquire); attempt++) usleep(1000);
    pthread_mutex_lock(&gStateLock);
    int slot=-1;
    for (int i=0;i<MaximumClients;i++) if (gClients[i].used && gClients[i].id == client) {slot=i;break;}
    if (slot<0) { pthread_mutex_unlock(&gStateLock);return kAudioHardwareIllegalOperationError; }
    if (gClients[slot].running) { pthread_mutex_unlock(&gStateLock);return noErr; }
    NakuAudioShared *shared=borrowShared();
    if (!shared) {returnShared();pthread_mutex_unlock(&gStateLock);return kAudioHardwareNotReadyError;}
    UInt32 count=atomic_load_explicit(&gRunning,memory_order_relaxed);
    if (!count) {
        atomic_store_explicit(&gAnchor,mach_absolute_time(),memory_order_release);
        atomic_fetch_add_explicit(&gSeed,1,memory_order_release);
        atomic_fetch_add_explicit(&shared->generation,1,memory_order_release);
        atomic_fetch_add_explicit(&shared->writerStarts,1,memory_order_relaxed);
    }
    gClients[slot].running=true;
    atomic_store_explicit(&gRunning,count+1,memory_order_release);
    atomic_store_explicit(&shared->writerActive,count+1,memory_order_release);
    returnShared();pthread_mutex_unlock(&gStateLock);
    if (!count) notifyRunning();
    return noErr;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    if (!validDriver(d) || id != NakuDevice) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateLock);
    for (int i=0;i<MaximumClients;i++) if (gClients[i].used && gClients[i].id == client && gClients[i].running) {
        gClients[i].running=false;
        UInt32 count=atomic_load_explicit(&gRunning,memory_order_relaxed);
        if (count) --count;
        atomic_store_explicit(&gRunning,count,memory_order_release);
        NakuAudioShared *shared=borrowShared();
        if (shared) atomic_store_explicit(&shared->writerActive,count,memory_order_release);
        returnShared();pthread_mutex_unlock(&gStateLock);
        if (!count) notifyRunning();
        return noErr;
    }
    pthread_mutex_unlock(&gStateLock);return noErr;
}
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                 Float64 *sample, UInt64 *host, UInt64 *seed) {
    (void)client;
    if (!validDriver(d) || id != NakuDevice) return kAudioHardwareBadDeviceError;
    if (!sample || !host || !seed || gTicksPerFrame<=0) return kAudioHardwareIllegalOperationError;
    uint64_t anchor=atomic_load_explicit(&gAnchor,memory_order_acquire),now=mach_absolute_time();
    uint64_t elapsed=now>=anchor?now-anchor:0;
    uint64_t periods=(uint64_t)((long double)elapsed/(gTicksPerFrame*TimestampPeriod));
    uint64_t frames=periods*TimestampPeriod;
    *sample=(Float64)frames;*host=anchor+(uint64_t)((long double)frames*gTicksPerFrame);
    *seed=atomic_load_explicit(&gSeed,memory_order_acquire);
    return noErr;
}
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                  UInt32 operation, Boolean *will, Boolean *inPlace) {
    (void)client;
    if (!validDriver(d) || id != NakuDevice) return kAudioHardwareBadDeviceError;
    if (!will || !inPlace) return kAudioHardwareIllegalOperationError;
    *will=operation == kAudioServerPlugInIOOperationWriteMix;*inPlace=true;return noErr;
}
static OSStatus BoundaryIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                           UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;(void)operation;(void)frames;(void)cycle;
    return validDriver(d) && id == NakuDevice ? noErr : kAudioHardwareBadDeviceError;
}
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream,
                              UInt32 client, UInt32 operation, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondary) {
    (void)client;(void)cycle;(void)secondary;
    if (!validDriver(d) || id != NakuDevice) return kAudioHardwareBadDeviceError;
    if (stream != NakuStream) return kAudioHardwareBadStreamError;
    if (operation != kAudioServerPlugInIOOperationWriteMix) return kAudioHardwareUnsupportedOperationError;
    if (frames>NAKU_AUDIO_CAPACITY || (frames && !mainBuffer)) return kAudioHardwareBadPropertySizeError;
    if (!frames) return noErr;
    if (!atomic_load_explicit(&gRunning,memory_order_acquire)) return kAudioHardwareNotRunningError;
    NakuAudioShared *shared=borrowShared();
    if (shared) {
        Float32 gain=(atomic_load_explicit(&gMuted,memory_order_relaxed) || !atomic_load_explicit(&gStreamActive,memory_order_relaxed)) ? 0 : readGain();
        const Float32 *samples=mainBuffer;
        uint64_t start=atomic_load_explicit(&shared->writeFrame,memory_order_relaxed);
        for (UInt32 frame=0;frame<frames;frame++) {
            UInt32 index=(UInt32)((start+frame)%NAKU_AUDIO_CAPACITY)*2;
            for (UInt32 channel=0;channel<2;channel++) {
                Float32 value=samples[frame*2+channel]*gain;
                if (!isfinite(value)) value=0;
                uint32_t bits;memcpy(&bits,&value,sizeof(bits));
                atomic_store_explicit(&shared->samples[index+channel],bits,memory_order_relaxed);
            }
        }
        atomic_store_explicit(&shared->writeFrame,start+frames,memory_order_release);
    }
    returnShared();return noErr;
}
static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    AddDeviceClient, RemoveDeviceClient, ConfigurationChange, ConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BoundaryIO, DoIOOperation, BoundaryIO
};
__attribute__((visibility("default"))) void *NakuAudio_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    if (!type || !CFEqual(type,kAudioServerPlugInTypeUUID)) return NULL;
    AddRef(gDriver);return gDriver;
}
