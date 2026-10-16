package com.example.kazumi
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

@Suppress("DEPRECATION")
class NakuDiscovery(context: Context, messenger: BinaryMessenger) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val channel = MethodChannel(messenger, "naku/lan")
    private val handler = Handler(Looper.getMainLooper())
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val pending = java.util.ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var generation = 0
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when(call.method) {
                    "advertise" -> {
                        registration?.let { manager.unregisterService(it) }
                        val listener = object : NsdManager.RegistrationListener {
                            override fun onServiceRegistered(info: NsdServiceInfo) {}
                            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { handler.post { channel.invokeMethod("error", "电视发现服务注册失败：$code") } }
                            override fun onServiceUnregistered(info: NsdServiceInfo) {}
                            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
                        }
                        registration=listener
                        val info=NsdServiceInfo().apply { serviceName="Naku-${call.argument<String>("id")}";serviceType="_nakuplay._tcp.";port=call.argument<Int>("port")!! }
                        manager.registerService(info,NsdManager.PROTOCOL_DNS_SD,listener);result.success(null)
                    }
                    "discover" -> {
                        stopDiscovery()
                        val listener=object:NsdManager.DiscoveryListener {
                            override fun onDiscoveryStarted(type:String) {}
                            override fun onServiceFound(info:NsdServiceInfo) { handler.post { if(info.serviceName.startsWith("Naku-")){pending.add(info);resolveNext()} } }
                            override fun onServiceLost(info:NsdServiceInfo) { handler.post {channel.invokeMethod("lost",info.serviceName.removePrefix("Naku-"))} }
                            override fun onDiscoveryStopped(type:String) {}
                            override fun onStartDiscoveryFailed(type:String,code:Int) { handler.post {channel.invokeMethod("error","无法发现电视：$code")} }
                            override fun onStopDiscoveryFailed(type:String,code:Int) {}
                        }
                        discovery=listener;manager.discoverServices("_nakuplay._tcp.",NsdManager.PROTOCOL_DNS_SD,listener);result.success(null)
                    }
                    "stop" -> {stopDiscovery();registration?.let {manager.unregisterService(it)};registration=null;result.success(null)}
                    else -> result.notImplemented()
                }
            } catch(_:Exception){result.error("lan","局域网发现服务不可用，请检查网络连接。",null)}
        }
    }
    fun dispose() {
        try { stopDiscovery() } catch (_: Exception) {}
        try { registration?.let { manager.unregisterService(it) } } catch (_: Exception) {}
        registration = null
        channel.setMethodCallHandler(null)
    }
    private fun stopDiscovery(){generation++;discovery?.let {manager.stopServiceDiscovery(it)};discovery=null;pending.clear()}
    private fun resolveNext(){
        if(resolving||pending.isEmpty())return
        resolving=true;val attempt=generation
        manager.resolveService(pending.removeFirst(),object:NsdManager.ResolveListener {
            override fun onResolveFailed(info:NsdServiceInfo,code:Int){handler.post {resolving=false;resolveNext()}}
            override fun onServiceResolved(info:NsdServiceInfo){handler.post {
                if(attempt==generation)channel.invokeMethod("found",mapOf("id" to info.serviceName.removePrefix("Naku-"),"host" to info.host?.hostAddress,"port" to info.port))
                resolving=false;resolveNext()
            }}
        })
    }
}
