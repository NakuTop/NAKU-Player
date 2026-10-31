#include "../../macos/AudioDriver/Shared/NakuAudioShared.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static bool accepted(const char *path, SecRequirementRef requirement) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
  SecStaticCodeRef code = NULL;
  OSStatus result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
  if (result == errSecSuccess) result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
  if (code) CFRelease(code); CFRelease(url);
  return result == errSecSuccess;
}
int main(int argc, const char **argv) {
  assert(argc > 0);
  SecRequirementRef requirement = NULL;
  assert(SecRequirementCreateWithString(CFSTR(NAKU_AUDIO_WRITER_REQUIREMENT), kSecCSDefaultFlags, &requirement) == errSecSuccess);
  assert(accepted("/usr/sbin/coreaudiod", requirement));
  assert(accepted("/System/Library/Frameworks/CoreAudio.framework/Versions/A/XPCServices/com.apple.audio.DriverHelper.xpc/Contents/MacOS/com.apple.audio.DriverHelper", requirement));
  assert(accepted("/System/Library/Frameworks/CoreAudio.framework/Versions/A/XPCServices/com.apple.audio.Core-Audio-Driver-Service.helper.xpc/Contents/MacOS/com.apple.audio.Core-Audio-Driver-Service.helper", requirement));
  if (argc == 2) {
    int pid = atoi(argv[1]);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid}, *values[] = {number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef process = NULL;
    assert(SecCodeCopyGuestWithAttributes(NULL, attributes, 0, &process) == errSecSuccess);
    assert(SecCodeCheckValidity(process, kSecCSStrictValidate, requirement) == errSecSuccess);
    CFRelease(process); CFRelease(attributes); CFRelease(number);
    puts("PASS live NAKU audio-driver host signature accepted");
  }
  assert(!accepted(argv[0], requirement));
  CFRelease(requirement);
  puts("PASS Apple CoreAudio hosts accepted; unsigned/ad-hoc client rejected as driver writer");
  return 0;
}
