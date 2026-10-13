"""Bounded headless decode check for synthetic NAKU integration fixtures."""
import ctypes
import json
import sys
import time

payload = json.load(sys.stdin)
lib = ctypes.CDLL(payload['library'])
class Event(ctypes.Structure):
    _fields_ = [('event_id', ctypes.c_int), ('error', ctypes.c_int),
                ('reply_userdata', ctypes.c_uint64), ('data', ctypes.c_void_p)]
class Log(ctypes.Structure):
    _fields_ = [('prefix', ctypes.c_char_p), ('level', ctypes.c_char_p),
                ('text', ctypes.c_char_p), ('log_level', ctypes.c_int)]
lib.mpv_create.restype = ctypes.c_void_p
lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.mpv_set_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.mpv_initialize.argtypes = [ctypes.c_void_p]
lib.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
lib.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
lib.mpv_wait_event.restype = ctypes.POINTER(Event)
lib.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.mpv_get_property_string.restype = ctypes.c_void_p
lib.mpv_free.argtypes = [ctypes.c_void_p]
lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
lib.mpv_request_log_messages.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
player = lib.mpv_create()
for key, value in {'vo':'null','ao':'null','hwdec':'no','terminal':'no','config':'no',
    'http-proxy':'','network-timeout':'10','tls-verify':'yes','idle':'yes'}.items():
    code = lib.mpv_set_option_string(player, key.encode(), value.encode())
    if code < 0: raise RuntimeError(f'Unsupported option {key}: {code}')
if lib.mpv_initialize(player) < 0: raise RuntimeError('Initialization failed')
lib.mpv_request_log_messages(player, b'warn')
def prop(name):
    pointer = lib.mpv_get_property_string(player, name.encode())
    if not pointer: return None
    value = ctypes.string_at(pointer).decode('utf-8', 'replace')
    lib.mpv_free(pointer)
    return value
facts = {}
try:
    lib.mpv_command(player, (ctypes.c_char_p * 4)(b'loadfile', payload['url'].encode(), b'replace', None))
    started = time.monotonic()
    while time.monotonic() - started < 15:
        event = lib.mpv_wait_event(player, .05).contents
        if event.event_id == 2 and event.data:
            log = ctypes.cast(event.data, ctypes.POINTER(Log)).contents
            sys.stderr.write(log.text.decode('utf-8', 'replace'))
        if event.event_id == 7: break
        at = float(prop('time-pos') or 0)
        if at >= 1.2 and prop('width'):
            facts = {name: prop(name) for name in ['width','height','container-fps','audio-codec',
                'time-pos','track-list/count','decoder-frame-drop-count','frame-drop-count']}
            code = lib.mpv_set_property_string(player, b'sub-delay', b'2.5')
            facts['subtitleDelayReturnCode'] = code
            facts['subtitleDelay'] = prop('sub-delay')
            break
finally:
    lib.mpv_terminate_destroy(player)
print(json.dumps(facts))
if not facts: sys.exit(1)
