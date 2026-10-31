// Offline contract test: calls our implementation directly, never opens HAL IO.
#define NAKU_AUDIO_DRIVER_TEST 1
#include "../NakuAudioDriver.c"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static OSStatus changed(AudioServerPlugInHostRef h,AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress *a){(void)h;(void)o;(void)n;(void)a;return noErr;}
static AudioObjectPropertyAddress prop(UInt32 selector,UInt32 scope){return(AudioObjectPropertyAddress){selector,scope,0};}
static UInt32 get32(AudioObjectID id,UInt32 selector,UInt32 scope){
 AudioObjectPropertyAddress a=prop(selector,scope);UInt32 v=0,n=0;
 assert(GetPropertyData(gDriver,id,0,&a,0,NULL,sizeof(v),&n,&v)==noErr&&n==sizeof(v));return v;
}
int main(void){
 AudioServerPlugInHostInterface host={.PropertiesChanged=changed};assert(Initialize(gDriver,&host)==noErr);
 assert(NakuAudio_Create(NULL,kAudioServerPlugInTypeUUID)==gDriver);
 assert(NakuAudio_Create(NULL,IUnknownUUID)==NULL);
 AudioObjectPropertyAddress a=prop(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput);UInt32 n=99;
 assert(GetPropertyDataSize(gDriver,NakuDevice,0,&a,0,NULL,&n)==noErr&&n==0);
 assert(GetPropertyData(gDriver,NakuDevice,0,&a,0,NULL,0,&n,NULL)==noErr&&n==0);
 for(int i=0;i<2;i++){
  a=prop(kAudioDevicePropertyStreams,i?kAudioObjectPropertyScopeGlobal:kAudioObjectPropertyScopeOutput);
  UInt32 stream=0;assert(GetPropertyData(gDriver,NakuDevice,0,&a,0,NULL,4,&n,&stream)==noErr&&n==4&&stream==NakuStream);
 }
 a=prop(kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeGlobal);AudioClassID classes[2]={kAudioStreamClassID,kAudioControlClassID};
 assert(GetPropertyDataSize(gDriver,NakuDevice,0,&a,sizeof(classes),classes,&n)==noErr&&n==3*sizeof(AudioObjectID));
 assert(GetPropertyDataSize(gDriver,NakuDevice,0,&a,1,classes,&n)==kAudioHardwareBadPropertySizeError);
 assert(get32(NakuDevice,kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioObjectPropertyScopeOutput)==1);
 assert(get32(NakuDevice,kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioObjectPropertyScopeInput)==0);
 a=prop(kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput);
 unsigned char empty[sizeof(AudioBufferList)]={0xff};assert(GetPropertyData(gDriver,NakuDevice,0,&a,0,NULL,sizeof(empty),&n,empty)==noErr);
 assert(n==offsetof(AudioBufferList,mBuffers)&&((AudioBufferList*)empty)->mNumberBuffers==0);
 a=prop(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal);AudioStreamBasicDescription format;
 assert(GetPropertyData(gDriver,NakuStream,0,&a,0,NULL,sizeof(format),&n,&format)==noErr);
 assert(format.mSampleRate==48000&&format.mChannelsPerFrame==2&&format.mBytesPerFrame==8&&sameFormat(&format));
 assert(SetPropertyData(gDriver,NakuStream,0,&a,0,NULL,sizeof(format),&format)==noErr);
 format.mSampleRate=44100;assert(SetPropertyData(gDriver,NakuStream,0,&a,0,NULL,sizeof(format),&format)==kAudioDeviceUnsupportedFormatError);
 a=prop(kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal);UInt32 word=0;
 assert(GetPropertyData(gDriver,NakuDevice,0,&a,0,NULL,1,&n,&word)==kAudioHardwareBadPropertySizeError);
 a=prop(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeInput);assert(!HasProperty(gDriver,NakuStream,0,&a));
 a=prop(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal);double rate=44100;
 assert(SetPropertyData(gDriver,NakuDevice,0,&a,0,NULL,sizeof(rate),&rate)==kAudioDeviceUnsupportedFormatError);
 assert(StartIO(gDriver,NakuDevice,123)==kAudioHardwareIllegalOperationError);
 AudioServerPlugInClientInfo one={.mClientID=123},two={.mClientID=456};
 assert(AddDeviceClient(gDriver,NakuDevice,&one)==noErr&&AddDeviceClient(gDriver,NakuDevice,&two)==noErr);
 assert(StartIO(gDriver,NakuDevice,123)==kAudioHardwareNotReadyError);
 NakuAudioShared *shared=calloc(1,sizeof(*shared));shared->magic=NAKU_AUDIO_MAGIC;shared->version=NAKU_AUDIO_ABI;
 shared->capacity=NAKU_AUDIO_CAPACITY;shared->sampleRate=NAKU_AUDIO_RATE;publishMapping(shared,0);
 uint64_t seedBefore=atomic_load(&gSeed);
 assert(StartIO(gDriver,NakuDevice,123)==noErr&&StartIO(gDriver,NakuDevice,123)==noErr);
 assert(atomic_load(&shared->writerActive)==1&&atomic_load(&shared->writerStarts)==1&&atomic_load(&gSeed)>seedBefore);
 assert(StartIO(gDriver,NakuDevice,456)==noErr&&atomic_load(&shared->writerActive)==2&&atomic_load(&shared->writerStarts)==1);
 Boolean will=false,inPlace=false;
 assert(WillDoIOOperation(gDriver,NakuDevice,0,kAudioServerPlugInIOOperationReadInput,&will,&inPlace)==noErr&&!will);
 assert(WillDoIOOperation(gDriver,NakuDevice,0,kAudioServerPlugInIOOperationWriteMix,&will,&inPlace)==noErr&&will&&inPlace);
 Float32 frames[1024];for(int i=0;i<1024;i++)frames[i]=(i%2?-.25f:.5f);
 for(int i=0;i<70;i++)assert(DoIOOperation(gDriver,NakuDevice,NakuStream,0,kAudioServerPlugInIOOperationWriteMix,512,NULL,frames,NULL)==noErr);
 assert(atomic_load(&shared->writeFrame)==70*512);
 uint32_t bits=atomic_load(&shared->samples[((70*512-1)%NAKU_AUDIO_CAPACITY)*2]);float sample;memcpy(&sample,&bits,4);assert(sample==.5f);
 a=prop(kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal);float gain=.5f;
 assert(SetPropertyData(gDriver,NakuVolume,0,&a,0,NULL,sizeof(gain),&gain)==noErr);
 assert(DoIOOperation(gDriver,NakuDevice,NakuStream,0,kAudioServerPlugInIOOperationWriteMix,512,NULL,frames,NULL)==noErr);
 bits=atomic_load(&shared->samples[((71*512-1)%NAKU_AUDIO_CAPACITY)*2]);memcpy(&sample,&bits,4);assert(sample==.25f);
 a=prop(kAudioBooleanControlPropertyValue,kAudioObjectPropertyScopeGlobal);word=1;
 assert(SetPropertyData(gDriver,NakuMute,0,&a,0,NULL,4,&word)==noErr);
 assert(DoIOOperation(gDriver,NakuDevice,NakuStream,0,kAudioServerPlugInIOOperationWriteMix,512,NULL,frames,NULL)==noErr);
 assert(atomic_load(&shared->samples[((72*512-1)%NAKU_AUDIO_CAPACITY)*2])==0);
 Float64 st;UInt64 ht,seed;assert(GetZeroTimeStamp(gDriver,NakuDevice,0,&st,&ht,&seed)==noErr);
 assert(st>=0&&fmod(st,TimestampPeriod)==0&&ht<=mach_absolute_time()&&seed==atomic_load(&gSeed));
 uint64_t savedAnchor=atomic_load(&gAnchor),now=mach_absolute_time();
 atomic_store(&gAnchor,now-(uint64_t)(gTicksPerFrame*(TimestampPeriod*2+1000)));
 assert(GetZeroTimeStamp(gDriver,NakuDevice,0,&st,&ht,&seed)==noErr&&st==TimestampPeriod*2&&ht<=mach_absolute_time());
 assert((long double)(mach_absolute_time()-ht)<gTicksPerFrame*TimestampPeriod);
 atomic_store(&gAnchor,savedAnchor);
 assert(StopIO(gDriver,NakuDevice,123)==noErr&&atomic_load(&shared->writerActive)==1);
 assert(RemoveDeviceClient(gDriver,NakuDevice,&two)==noErr&&atomic_load(&shared->writerActive)==0);
 assert(StopIO(gDriver,NakuDevice,123)==noErr);
 assert(get32(NakuDevice,kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal)==0);
 uint64_t starts=atomic_load(&shared->writerStarts);assert(StartIO(gDriver,NakuDevice,123)==noErr&&atomic_load(&shared->writerStarts)==starts+1);
 assert(StopIO(gDriver,NakuDevice,123)==noErr);publishMapping(NULL,0);free(shared);
 puts("PASS output-only property/scopes/sizes/fixed-format/default-capability");
 puts("PASS shared-ring wrap/channel layout/gain/mute/active-client lifecycle");
 puts("PASS clock anchor/seed lifecycle; no HAL IO, route changes or installation");
 return 0;
}
