#!/usr/bin/env python3
"""Build the same bundled VAD/Vision code and test self-authored speech offline."""
import argparse
import json
from pathlib import Path
import random
import shutil
import wave
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
output=args.output.resolve()
output.mkdir(parents=True,exist_ok=True)
phrases=[
 'Please bring the blue notebook tomorrow morning.',
 'We found a little wooden boat beside the river.',
 'The next train leaves at seven in the evening.',
 'Could you open the window before we start the meeting?',
 'There is a small red house at the end of this road.',
 'I remember that we planted flowers here last summer.',
 'Let us finish the work and then have some dinner.',
 'Nobody knows why the clock stopped during the night.',
]
frameworks=root/'build/macos/Build/Products/Release/NAKUPlayer.app/Contents/Frameworks'
probe=output/'pcm-probe'
probe_source=output/'pcm-probe.c'
probe_source.write_text('''#include "mpv/client.h"
int main(int n,char**v){if(n!=3)return 2;mpv_handle*p=mpv_create();
const char*k[]={"vo","ao","vid","audio-samplerate","audio-channels","audio-format","ao-pcm-waveheader","ao-pcm-file","untimed"};
const char*x[]={"null","pcm","no","16000","mono","s16","no",v[2],"yes"};
if(mpv_initialize(p)<0)return 3;for(int i=0;i<9;i++)if(mpv_set_property_string(p,k[i],x[i])<0)return 4;
const char*load[]={"loadfile",v[1],0};if(mpv_command(p,load)<0)return 5;
for(int i=0;i<150;i++){mpv_event*e=mpv_wait_event(p,.1);if(e->event_id==MPV_EVENT_END_FILE){mpv_terminate_destroy(p);return 0;}}return 6;}
''')
subprocess.run(['clang',str(probe_source),'-I',str(root/'third_party/media_kit_video/common/mpv/include'),'-F',str(frameworks),'-framework','Mpv',f'-Wl,-rpath,{frameworks}','-o',str(probe)],check=True)
clips=[]
for i,text in enumerate(phrases):
 aiff=output/f'voice-{i}.aiff';pcm=output/f'voice-{i}.pcm'
 subprocess.run(['/usr/bin/say','-v','Samantha','-o',str(aiff),text],check=True)
 subprocess.run([str(probe),str(aiff),str(pcm)],check=True,timeout=20)
 clips.append(pcm.read_bytes())
rng=random.Random(1405)
audio=bytearray(b'\0'*(16000*2*3));cues=[]
while len(audio)<16000*2*330:
 clip=clips[rng.randrange(len(clips))]
 start=len(audio)/32
 audio.extend(clip)
 cues.append([round(start),round(len(audio)/32)])
 audio.extend(b'\0'*(2*rng.randrange(6000,92000)))
(output/'dialogue.pcm').write_bytes(audio)
with wave.open(str(output/'dialogue.wav'),'wb') as wav:
 wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(audio)
(output/'cues.json').write_text(json.dumps({'cues':cues}))
objects=[]
for source in sorted((root/'third_party/libfvad/src').rglob('*.c')):
 obj=output/(source.stem+'.o');objects.append(str(obj))
 subprocess.run(['clang','-O2','-I',str(root/'third_party/libfvad/include'),'-c',str(source),'-o',str(obj)],check=True)
shutil.copyfile(root/'test/native/subtitle_tools_test.swift',output/'main.swift')
binary=output/'subtitle-tools-test'
subprocess.run(['swiftc','-O','-import-objc-header',str(root/'macos/Runner/SubtitleTools-Bridging-Header.h'),str(root/'macos/Runner/NakuSubtitleTools.swift'),str(output/'main.swift'),*objects,'-o',str(binary)],check=True)
subprocess.run([str(binary),str(output/'dialogue.pcm'),str(output/'cues.json'),str(output/'voice-fixture.json')],check=True,timeout=40)
print('Fixture:',output/'voice-fixture.json')
