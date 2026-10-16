package com.example.kazumi

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.KeyStore
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Device-bound credentials. Backups are disabled in the manifest. */
class NakuSecureBridge(private val context: Context) {
    private var qrKey: KeyPair? = null
    private val alias = "naku.nas.credentials.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun encrypt(bytes: ByteArray, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return cipher.iv + cipher.doFinal(bytes)
    }
    private fun decrypt(bytes: ByteArray, key: SecretKey): ByteArray {
        require(bytes.size >= 28)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            doFinal(bytes.copyOfRange(12, bytes.size))
        }
    }
    private fun b64(data: ByteArray) = Base64.encodeToString(data, Base64.NO_WRAP)
    private fun decode(text: String) = Base64.decode(text, Base64.DEFAULT)
    private fun derLength(size: Int): ByteArray = when {
        size < 128 -> byteArrayOf(size.toByte())
        size < 256 -> byteArrayOf(0x81.toByte(), size.toByte())
        else -> byteArrayOf(0x82.toByte(), (size shr 8).toByte(), size.toByte())
    }
    private fun rsa(text: String, raw: String): String {
        val pem = if (raw.contains("BEGIN")) raw else String(decode(raw), Charsets.UTF_8)
        var der = decode(pem.replace(Regex("-----[^-]+-----|\\s"), ""))
        val factory = KeyFactory.getInstance("RSA")
        val spki = try { factory.generatePublic(X509EncodedKeySpec(der)) } catch (_: Exception) { null }
        if (spki == null && pem.contains("BEGIN RSA PUBLIC KEY")) {
            val algorithm = byteArrayOf(0x30,0x0d,0x06,0x09,0x2a,0x86.toByte(),0x48,0x86.toByte(),0xf7.toByte(),0x0d,0x01,0x01,0x01,0x05,0x00)
            val bits = byteArrayOf(0x03) + derLength(der.size + 1) + byteArrayOf(0) + der
            val body = algorithm + bits
            der = byteArrayOf(0x30) + derLength(body.size) + body
        }
        val publicKey = spki ?: factory.generatePublic(X509EncodedKeySpec(der))
        return Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
            init(Cipher.ENCRYPT_MODE, publicKey)
            b64(doFinal(text.toByteArray(Charsets.UTF_8)))
        }
    }
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "naku/secure").setMethodCallHandler { call, result ->
            try {
                val prefs = context.getSharedPreferences("naku-secure", Context.MODE_PRIVATE)
                val value: Any? = when (call.method) {
                    "qrKey" -> {
                        qrKey = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
                        "-----BEGIN RSA PUBLIC KEY-----\n" + b64(qrKey!!.public.encoded).chunked(64).joinToString("\n") + "\n-----END RSA PUBLIC KEY-----"
                    }
                    "qrDecrypt" -> Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
                        init(Cipher.DECRYPT_MODE, requireNotNull(qrKey).private)
                        String(doFinal(decode(call.argument<String>("text")!!)), Charsets.UTF_8)
                    }
                    "qrClear" -> { qrKey = null; null }
                    "read" -> prefs.getString("credentials", null)?.let { String(decrypt(decode(it), key()), Charsets.UTF_8) }
                    "write" -> { check(prefs.edit().putString("credentials", b64(encrypt(call.argument<String>("value")!!.toByteArray(Charsets.UTF_8), key()))).commit()); null }
                    "delete" -> { check(prefs.edit().remove("credentials").commit()); null }
                    "rsa" -> rsa(call.argument<String>("text")!!, call.argument<String>("key")!!)
                    "seal" -> b64(encrypt(call.argument<String>("text")!!.toByteArray(Charsets.UTF_8), SecretKeySpec(call.argument<String>("key")!!.toByteArray(Charsets.UTF_8), "AES")))
                    "open" -> String(decrypt(decode(call.argument<String>("text")!!), SecretKeySpec(call.argument<String>("key")!!.toByteArray(Charsets.UTF_8), "AES")), Charsets.UTF_8)
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                result.success(value)
            } catch (_: Exception) {
                result.error("secure", "无法读取本机加密凭据或处理 NAS 加密数据，请重新登录。", null)
            }
        }
    }
}
