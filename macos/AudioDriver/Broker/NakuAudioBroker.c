// NAKU's output-only virtual device bridge. No microphone, input device, audio
// recording API, command execution service, or persistent audio storage.
#include "../Shared/NakuAudioShared.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define CONFIG "/Library/Application Support/NAKUAudio/authorization.plist"
#define STATUS_FILE "/Library/Application Support/NAKUAudio/driver-status.plist"
static NakuAudioShared *shared;
static xpc_object_t memoryObject;
static xpc_connection_t readerPeer, writerPeer;
static SecRequirementRef readerRequirement, writerRequirement;
static uid_t ownerUID;
static char previousOutput[1024], previousSystem[1024];
static bool armed;

static void writeDriverStatus(bool ready) {
  // Only public readiness metadata; PCM stays exclusively in shared memory.
  char temporary[] = STATUS_FILE ".XXXXXX";
  int fd = mkstemp(temporary); if (fd < 0) return;
  bool ok = dprintf(fd, "<?xml version=\"1.0\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>version</key><integer>1</integer><key>driverReady</key><%s/><key>pid</key><integer>%d</integer></dict></plist>", ready ? "true" : "false", (int)getpid()) > 0;
  if (fchmod(fd, 0644) || fsync(fd)) ok = false;
  close(fd);
  if (!ok || rename(temporary, STATUS_FILE)) unlink(temporary);
}

static void reply(xpc_object_t message, bool ok, int code, const char *error, bool includeMemory) {
  xpc_object_t result = xpc_dictionary_create_reply(message);
  if (!result) return;
  xpc_dictionary_set_bool(result, "ok", ok);
  xpc_dictionary_set_int64(result, "errorCode", code);
  xpc_dictionary_set_uint64(result, "version", NAKU_AUDIO_ABI);
  if (error) xpc_dictionary_set_string(result, "error", error);
  if (includeMemory) xpc_dictionary_set_value(result, "shmem", memoryObject);
  xpc_connection_send_message(xpc_dictionary_get_remote_connection(message), result);
  xpc_release(result);
}

static bool checkIdentity(xpc_object_t message, SecRequirementRef requirement) {
  SecCodeRef process = NULL;
  // This API uses the message's audit token, avoiding PID reuse races.
  OSStatus status = SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &process);
  if (status == errSecSuccess)
    status = SecCodeCheckValidity(process, kSecCSStrictValidate, requirement);
  if (process) CFRelease(process);
  return status == errSecSuccess;
}

static AudioDeviceID defaultDevice(AudioObjectPropertySelector selector) {
  AudioDeviceID device = kAudioObjectUnknown; UInt32 size = sizeof(device);
  AudioObjectPropertyAddress p = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &p, 0, NULL, &size, &device) != noErr)
    return kAudioObjectUnknown;
  return device;
}

static bool deviceUID(AudioDeviceID device, char *buffer, size_t capacity) {
  if (device == kAudioObjectUnknown) return false;
  CFStringRef value = NULL; UInt32 size = sizeof(value);
  AudioObjectPropertyAddress p = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device, &p, 0, NULL, &size, &value) != noErr || !value) return false;
  bool result = CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
  CFRelease(value); return result;
}

static AudioDeviceID findDevice(const char *uid) {
  if (!uid || !uid[0] || strcmp(uid, NAKU_AUDIO_DEVICE_UID) == 0) return kAudioObjectUnknown;
  AudioObjectPropertyAddress p = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &p, 0, NULL, &size) != noErr || size > 65536) return kAudioObjectUnknown;
  AudioDeviceID *devices = calloc(1, size ? size : sizeof(AudioDeviceID));
  if (!devices) return kAudioObjectUnknown;
  AudioDeviceID result = kAudioObjectUnknown;
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &p, 0, NULL, &size, devices) == noErr) {
    for (size_t i = 0; i < size / sizeof(AudioDeviceID); i++) {
      char value[1024];
      if (deviceUID(devices[i], value, sizeof(value)) && strcmp(value, uid) == 0) {
        UInt32 canDefault = 0, n = sizeof(canDefault);
        AudioObjectPropertyAddress capability = {kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(devices[i], &capability, 0, NULL, &n, &canDefault) == noErr && canDefault)
          result = devices[i];
        break;
      }
    }
  }
  free(devices); return result;
}

static void restoreOne(AudioObjectPropertySelector selector, const char *uid) {
  char current[1024];
  if (!deviceUID(defaultDevice(selector), current, sizeof(current)) || strcmp(current, NAKU_AUDIO_DEVICE_UID)) return;
  AudioDeviceID previous = findDevice(uid);
  if (previous == kAudioObjectUnknown) return;
  AudioObjectPropertyAddress p = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  OSStatus result = AudioObjectSetPropertyData(kAudioObjectSystemObject, &p, 0, NULL, sizeof(previous), &previous);
  fprintf(stderr, "NAKU audio recovery selector=%u status=%d\n", selector, (int)result);
}

static void restoreRoute(void) {
  if (!armed) return;
  restoreOne(kAudioHardwarePropertyDefaultOutputDevice, previousOutput);
  restoreOne(kAudioHardwarePropertyDefaultSystemOutputDevice, previousSystem);
  armed = false;
}

static void handle(xpc_connection_t peer, xpc_object_t message) {
  if (xpc_get_type(message) == XPC_TYPE_ERROR) {
    if (message != XPC_ERROR_CONNECTION_INVALID) return;
    if (peer == readerPeer) {
      restoreRoute(); xpc_release(readerPeer); readerPeer = NULL;
      atomic_fetch_add_explicit(&shared->generation, 1, memory_order_release);
    }
    if (peer == writerPeer) {
      xpc_release(writerPeer); writerPeer = NULL;
      writeDriverStatus(false);
      atomic_store_explicit(&shared->writerActive, 0, memory_order_release);
      // Losing the output host must release a live route rather than leave
      // the Mac silently sending audio to a device without a writer.
      if (readerPeer) { restoreRoute(); xpc_connection_cancel(readerPeer); }
    }
    return;
  }
  if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
  const char *op = xpc_dictionary_get_string(message, "op");
  if (!op) { reply(message, false, 1, "Missing operation", false); return; }
  if (!strcmp(op, "attach")) {
    if (xpc_dictionary_get_uint64(message, "version") != NAKU_AUDIO_ABI) {
      reply(message, false, 1, "Audio driver version mismatch", false); return;
    }
    const char *role = xpc_dictionary_get_string(message, "role");
    if (role && !strcmp(role, "writer") && checkIdentity(message, writerRequirement)) {
      if (writerPeer && writerPeer != peer) { reply(message, false, 3, "Writer already attached", false); return; }
      if (!writerPeer) { writerPeer = peer; xpc_retain(peer); writeDriverStatus(true); }
      reply(message, true, 0, NULL, true); return;
    }
    if (role && !strcmp(role, "reader") && xpc_connection_get_euid(peer) == ownerUID && checkIdentity(message, readerRequirement)) {
      if (readerPeer && readerPeer != peer) { reply(message, false, 3, "Another NAKU session is active", false); return; }
      if (!readerPeer) { readerPeer = peer; xpc_retain(peer); }
      reply(message, true, 0, NULL, true); return;
    }
    reply(message, false, 2, "NAKU authorization needs updating", false); return;
  }
  if (peer != readerPeer || xpc_connection_get_euid(peer) != ownerUID || !checkIdentity(message, readerRequirement)) {
    reply(message, false, 2, "Unauthorized audio control", false); return;
  }
  if (!strcmp(op, "arm")) {
    if (!writerPeer) { reply(message, false, 1, "NAKU audio driver is not ready; try again shortly", false); return; }
    const char *output = xpc_dictionary_get_string(message, "previousOutput");
    const char *system = xpc_dictionary_get_string(message, "previousSystem");
    if (!output || strnlen(output, sizeof(previousOutput)) >= sizeof(previousOutput) || findDevice(output) == kAudioObjectUnknown ||
        (system && strnlen(system, sizeof(previousSystem)) >= sizeof(previousSystem))) {
      reply(message, false, 1, "Invalid previous output device", false); return;
    }
    strlcpy(previousOutput, output, sizeof(previousOutput));
    strlcpy(previousSystem, system ? system : "", sizeof(previousSystem));
    armed = true; reply(message, true, 0, NULL, false); return;
  }
  if (!strcmp(op, "disarm")) { restoreRoute(); reply(message, true, 0, NULL, false); return; }
  reply(message, false, 1, "Unsupported audio control", false);
}

static bool loadAuthorization(void) {
  struct stat info;
  if (lstat(CONFIG, &info) || !S_ISREG(info.st_mode) || info.st_uid || (info.st_mode & 0022)) return false;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)CONFIG, strlen(CONFIG), false);
  CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url); CFRelease(url);
  if (!stream || !CFReadStreamOpen(stream)) { if (stream) CFRelease(stream); return false; }
  CFPropertyListRef list = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);
  CFReadStreamClose(stream); CFRelease(stream);
  if (!list || CFGetTypeID(list) != CFDictionaryGetTypeID()) { if (list) CFRelease(list); return false; }
  CFStringRef requirement = CFDictionaryGetValue(list, CFSTR("requirement"));
  CFNumberRef uid = CFDictionaryGetValue(list, CFSTR("ownerUID")); int64_t number = 0;
  bool valid = requirement && CFGetTypeID(requirement) == CFStringGetTypeID() && uid && CFGetTypeID(uid) == CFNumberGetTypeID() &&
    CFNumberGetValue(uid, kCFNumberSInt64Type, &number) && number > 0 && number <= UINT32_MAX &&
    SecRequirementCreateWithString(requirement, kSecCSDefaultFlags, &readerRequirement) == errSecSuccess;
  ownerUID = (uid_t)number; CFRelease(list); return valid;
}

static int authorizeApp(const char *path) {
  char resolved[PATH_MAX];
  if (geteuid() || !realpath(path, resolved) || strncmp(resolved, "/Applications/", 14)) return 2;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)resolved, strlen(resolved), true);
  CFBundleRef bundle = CFBundleCreate(NULL, url);
  CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
  SecStaticCodeRef code = NULL; SecRequirementRef requirement = NULL; CFStringRef text = NULL;
  OSStatus status = identifier && CFEqual(identifier, CFSTR(NAKU_AUDIO_APP_ID)) ? SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) : errSecParam;
  if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, NULL);
  if (status == errSecSuccess) status = SecCodeCopyDesignatedRequirement((SecCodeRef)code, kSecCSDefaultFlags, &requirement);
  if (status == errSecSuccess) status = SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text);
  if (requirement) CFRelease(requirement); if (code) CFRelease(code); if (bundle) CFRelease(bundle); CFRelease(url);
  if (status != errSecSuccess || !text) { fprintf(stderr, "NAKU app signature check failed: %d\n", (int)status); return 3; }
  uid_t uid = 0; gid_t gid = 0;
  CFStringRef console = SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
  if (console) CFRelease(console);
  if (!uid || uid == (uid_t)-1) { CFRelease(text); return 4; }
  int64_t value = uid; CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
  CFStringRef appPath = CFStringCreateWithCString(NULL, resolved, kCFStringEncodingUTF8);
  const void *keys[] = {CFSTR("requirement"), CFSTR("ownerUID"), CFSTR("appPath")};
  const void *values[] = {text, number, appPath};
  CFDictionaryRef dictionary = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDataRef data = CFPropertyListCreateData(NULL, dictionary, kCFPropertyListXMLFormat_v1_0, 0, NULL);
  CFRelease(dictionary); CFRelease(appPath); CFRelease(number); CFRelease(text);
  if (!data) return 5;
  char temporary[] = CONFIG ".XXXXXX"; int fd = mkstemp(temporary); bool ok = fd >= 0;
  if (ok) {
    CFIndex size = CFDataGetLength(data), offset = 0;
    while (offset < size) { ssize_t n = write(fd, CFDataGetBytePtr(data) + offset, (size_t)(size-offset)); if (n <= 0) { ok = false; break; } offset += n; }
    if (fchmod(fd, 0644) || fsync(fd)) ok = false;
    close(fd); if (ok && rename(temporary, CONFIG)) ok = false;
    if (!ok) unlink(temporary);
  }
  CFRelease(data); return ok ? 0 : 6;
}

int main(int argc, const char **argv) {
  if (argc == 3 && !strcmp(argv[1], "--authorize-app")) return authorizeApp(argv[2]);
  if (geteuid() || !loadAuthorization()) { fprintf(stderr, "NAKU audio authorization missing\n"); return 1; }
  writeDriverStatus(false);
  // Recent macOS runs third-party HAL plugins in Apple's isolated DriverHelper;
  // older releases host them in coreaudiod. Restrict both to Apple's signature.
  if (SecRequirementCreateWithString(CFSTR(NAKU_AUDIO_WRITER_REQUIREMENT), kSecCSDefaultFlags, &writerRequirement) != errSecSuccess) return 1;
  shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  if (shared == MAP_FAILED) return 1;
  memset(shared, 0, sizeof(*shared));
  shared->magic = NAKU_AUDIO_MAGIC; shared->version = NAKU_AUDIO_ABI;
  shared->capacity = NAKU_AUDIO_CAPACITY; shared->sampleRate = NAKU_AUDIO_RATE;
  atomic_init(&shared->writeFrame, 0); atomic_init(&shared->generation, 0);
  atomic_init(&shared->writerStarts, 0); atomic_init(&shared->writerActive, 0);
  for (size_t i = 0; i < NAKU_AUDIO_CAPACITY * NAKU_AUDIO_CHANNELS; i++) atomic_init(&shared->samples[i], 0);
  memoryObject = xpc_shmem_create(shared, sizeof(*shared)); if (!memoryObject) return 1;
  dispatch_queue_t queue = dispatch_queue_create("com.shenminghao.naku.audio-broker", DISPATCH_QUEUE_SERIAL);
  xpc_connection_t listener = xpc_connection_create_mach_service(NAKU_AUDIO_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
  if (!listener) return 1;
  xpc_connection_set_event_handler(listener, ^(xpc_object_t object) {
    if (xpc_get_type(object) != XPC_TYPE_CONNECTION) return;
    xpc_connection_t peer = object;
    xpc_connection_set_target_queue(peer, queue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) { handle(peer, message); });
    xpc_connection_resume(peer);
  });
  xpc_connection_resume(listener); dispatch_main(); return 0;
}
