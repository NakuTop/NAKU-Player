"""Exercise the packaged libmpv against a generated, rate-limited HTTP WAV."""
import ctypes, http.server, json, re, struct, sys, threading, time
payload=json.load(sys.stdin)
data_size=1024*1024*1024
header=b'RIFF'+struct.pack('<I',data_size+36)+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,2,48000,192000,4,16)+b'data'+struct.pack('<I',data_size)
zero=bytes(65536)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        length=data_size+44
        match=re.match(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        start=int(match[1]) if match else 0
        end=int(match[2]) if match and match[2] else length-1
        end=min(end,length-1)
        self.send_response(206 if match else 200)
        self.send_header('Content-Type','audio/wav');self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes')
        if match:self.send_header('Content-Range',f'bytes {start}-{end}/{length}')
        self.end_headers()
        try:
            at=start
            while at<=end:
                if at<44:part=header[at:min(44,end+1)]
                else:part=zero[:min(len(zero),end-at+1)]
                self.wfile.write(part);self.wfile.flush();at+=len(part)
                time.sleep(len(part)/(16*1024*1024))
        except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
lib=ctypes.CDLL(payload['library'])
lib.mpv_create.restype=ctypes.c_void_p
for name in ['mpv_set_option_string','mpv_set_property_string']:getattr(lib,name).argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lib.mpv_initialize.argtypes=[ctypes.c_void_p]
lib.mpv_command.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_char_p)]
lib.mpv_get_property_string.argtypes=[ctypes.c_void_p,ctypes.c_char_p];lib.mpv_get_property_string.restype=ctypes.c_void_p
lib.mpv_free.argtypes=[ctypes.c_void_p];lib.mpv_terminate_destroy.argtypes=[ctypes.c_void_p]
class Node(ctypes.Structure): pass
class NodeList(ctypes.Structure): pass
class NodeUnion(ctypes.Union):
    _fields_=[('string',ctypes.c_char_p),('flag',ctypes.c_int),('int64',ctypes.c_int64),('double',ctypes.c_double),('list',ctypes.POINTER(NodeList))]
Node._fields_=[('u',NodeUnion),('format',ctypes.c_int)]
NodeList._fields_=[('num',ctypes.c_int),('values',ctypes.POINTER(Node)),('keys',ctypes.POINTER(ctypes.c_char_p))]
lib.mpv_get_property.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_void_p]
lib.mpv_free_node_contents.argtypes=[ctypes.POINTER(Node)]
def cache_state():
    node=Node();result={}
    if lib.mpv_get_property(player,b'demuxer-cache-state',6,ctypes.byref(node))>=0:
        try:
            if node.format==8:
                rows=node.u.list.contents
                for i in range(rows.num):
                    v=rows.values[i];k=rows.keys[i].decode()
                    if v.format==4:result[k]=v.u.int64
                    elif v.format==5:result[k]=v.u.double
                    elif v.format==3:result[k]=bool(v.u.flag)
        finally:lib.mpv_free_node_contents(ctypes.byref(node))
    return result
player=lib.mpv_create()
def prop(key):
    p=lib.mpv_get_property_string(player,key.encode())
    if not p:return ''
    try:return ctypes.string_at(p).decode()
    finally:lib.mpv_free(p)
def set_prop(k,v):
    code=lib.mpv_set_property_string(player,k.encode(),str(v).encode())
    if code<0:raise RuntimeError(f'Property {k}: {code}')
def sample():
    return {'bytes':int(cache_state().get('fw-bytes',0)),'seconds':float(prop('demuxer-cache-duration') or 0),'end':float(prop('demuxer-cache-time') or 0),'paused':prop('pause'),'idle':prop('demuxer-cache-idle'),'position':float(prop('time-pos') or 0)}
try:
    for k,v in {'vo':'null','ao':'null','terminal':'no','config':'no','pause':'yes','cache':'yes','cache-on-disk':'no','cache-secs':'30','demuxer-readahead-secs':'30','demuxer-max-bytes':str(256*1024*1024)}.items():
        if lib.mpv_set_option_string(player,k.encode(),v.encode())<0:raise RuntimeError(k)
    if lib.mpv_initialize(player)<0:raise RuntimeError('initialize')
    url=f'http://127.0.0.1:{server.server_port}/virtual.wav'
    if lib.mpv_command(player,(ctypes.c_char_p*3)(b'loadfile',url.encode(),None))<0:raise RuntimeError('load')
    time.sleep(2);before=sample(); sys.stderr.write('CACHE_RAW '+str(prop('demuxer-cache-state'))+'\n')
    assert 20<before['seconds']<40,before
    for k,v in payload['properties'].items():set_prop(k,v)
    lib.mpv_command(player,(ctypes.c_char_p*3)(b'loadfile',url.encode(),None))
    start=time.monotonic();progress=[]
    while time.monotonic()-start<38:
        time.sleep(.5);current=sample();progress.append(current)
        if current['bytes']>=255*1024*1024 and current['idle']=='yes':break
    filled=sample()
    assert filled['paused']=='yes',filled
    assert filled['bytes']>=255*1024*1024,filled
    assert filled['bytes']<=280*1024*1024,filled
    assert filled['seconds']>before['seconds']*20,filled
    set_prop('pause','no');time.sleep(1);playing_before=sample();time.sleep(4);playing_after=sample()
    assert playing_after['position']>playing_before['position']+2,playing_after
    assert playing_after['end']>playing_before['end']+1,playing_after
    print(json.dumps({'baseline':before,'pausedFilled':filled,'refillWallSeconds':round(time.monotonic()-start-5,2),'playingBefore':playing_before,'playingAfter':playing_after}))
finally:
    lib.mpv_terminate_destroy(player);server.shutdown();server.server_close()
