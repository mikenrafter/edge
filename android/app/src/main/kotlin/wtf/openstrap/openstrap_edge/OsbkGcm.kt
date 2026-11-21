package wtf.openstrap.openstrap_edge

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Streaming AES-256-GCM (96-bit nonce, 128-bit tag) for OSBK files, byte-identical to the Dart
 * pointycastle path in lib/import/backup_crypto.dart for the same key, nonce and header, including
 * pointycastle's 32-bit ciphertext length above 512 MiB (see [Ghash.tag]).
 *
 * Why not Cipher "AES/GCM/NoPadding": Android's provider (Conscrypt) buffers the whole input until
 * doFinal, which is an out-of-memory crash on a ~1 GB export. AES/CTR streams and uses the
 * platform's hardware AES; GHASH runs here with Shoup's 4-bit tables.
 */
class OsbkGcm(key: ByteArray, private val nonce: ByteArray, private val aad: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val hh = LongArray(16)
    private val hl = LongArray(16)
    private val tagMask: ByteArray

    init {
        require(key.size == 32 && nonce.size == 12) { "OSBK uses AES-256 with a 12-byte nonce" }
        val ecb = Cipher.getInstance("AES/ECB/NoPadding").apply { init(Cipher.ENCRYPT_MODE, keySpec) }
        val h = ecb.doFinal(ByteArray(16))
        tagMask = ecb.doFinal(counterBlock(1))
        var vh = be64(h, 0)
        var vl = be64(h, 8)
        hl[8] = vl; hh[8] = vh
        var i = 4
        while (i > 0) {
            val t = if ((vl and 1L) != 0L) 0xe1000000L else 0L
            vl = (vh shl 63) or (vl ushr 1)
            vh = (vh ushr 1) xor (t shl 32)
            hl[i] = vl; hh[i] = vh
            i = i shr 1
        }
        i = 2
        while (i <= 8) {
            vh = hh[i]; vl = hl[i]
            for (j in 1 until i) { hh[i + j] = vh xor hh[j]; hl[i + j] = vl xor hl[j] }
            i *= 2
        }
    }

    private fun counterBlock(counter: Int): ByteArray = ByteArray(16).also {
        System.arraycopy(nonce, 0, it, 0, 12)
        it[12] = (counter ushr 24).toByte(); it[13] = (counter ushr 16).toByte()
        it[14] = (counter ushr 8).toByte(); it[15] = counter.toByte()
    }

    private fun ctr(mode: Int): Cipher = Cipher.getInstance("AES/CTR/NoPadding").apply {
        // GCM's inc32 and CTR's 128-bit increment agree below 2^32 blocks (64 GiB).
        init(mode, keySpec, IvParameterSpec(counterBlock(2)))
    }

    /** GHASH state over AAD then ciphertext; [update] takes any lengths. */
    private inner class Ghash {
        private var zh = 0L
        private var zl = 0L
        private val block = ByteArray(16)
        private var fill = 0
        private var aadBits = 0L
        private var dataBits = 0L

        fun aad(bytes: ByteArray) { feed(bytes, 0, bytes.size); pad(); aadBits = bytes.size * 8L }

        fun update(bytes: ByteArray, off: Int, len: Int) { feed(bytes, off, len); dataBits += len * 8L }

        private fun feed(bytes: ByteArray, off: Int, len: Int) {
            var p = off
            val end = off + len
            if (fill > 0) {
                while (fill < 16 && p < end) block[fill++] = bytes[p++]
                if (fill < 16) return
                absorb(block, 0); fill = 0
            }
            while (end - p >= 16) { absorb(bytes, p); p += 16 }
            while (p < end) block[fill++] = bytes[p++]
        }

        private fun pad() {
            if (fill == 0) return
            java.util.Arrays.fill(block, fill, 16, 0)
            absorb(block, 0); fill = 0
        }

        private fun absorb(x: ByteArray, off: Int) {
            zh = zh xor be64(x, off)
            zl = zl xor be64(x, off + 8)
            mult()
        }

        // mbedtls gcm_mult, reading the 16 bytes of (zh, zl) from last to first.
        private fun mult() {
            val xh = zh
            val xl = zl
            var lo = (xl and 0xf).toInt()
            var h = hh[lo]
            var l = hl[lo]
            for (i in 15 downTo 0) {
                val b = (((if (i < 8) xh else xl) ushr ((7 - (i and 7)) * 8)) and 0xff).toInt()
                lo = b and 0xf
                val hi = b ushr 4
                if (i != 15) {
                    val rem = (l and 0xf).toInt()
                    l = (h shl 60) or (l ushr 4)
                    h = (h ushr 4) xor (LAST4[rem] shl 48)
                    h = h xor hh[lo]; l = l xor hl[lo]
                }
                val rem = (l and 0xf).toInt()
                l = (h shl 60) or (l ushr 4)
                h = (h ushr 4) xor (LAST4[rem] shl 48)
                h = h xor hh[hi]; l = l xor hl[hi]
            }
            zh = h; zl = l
        }

        fun tag(): ByteArray {
            pad()
            zh = zh xor aadBits
            // pointycastle 3.9 (what every OSBK reader, official v0.12.2 included, runs) stores the
            // ciphertext bit length in a Uint32, so above 512 MiB its tag covers the length mod 2^32.
            // Standard GCM would make those files unreadable there; match the format, not the RFC.
            zl = zl xor (dataBits and 0xffffffffL)
            mult()
            val out = ByteArray(16)
            put64(out, 0, zh); put64(out, 8, zl)
            for (k in 0 until 16) out[k] = (out[k].toInt() xor tagMask[k].toInt()).toByte()
            return out
        }
    }

    /** Writes header, ciphertext and tag to [out]; returns the plaintext SHA-256 (hex). */
    fun encrypt(input: InputStream, out: OutputStream, onBytes: (Long) -> Unit, cancelled: () -> Boolean): String {
        val ghash = Ghash().apply { aad(this@OsbkGcm.aad) }
        val sha = MessageDigest.getInstance("SHA-256")
        val cipher = ctr(Cipher.ENCRYPT_MODE)
        val buf = ByteArray(CHUNK)
        val enc = ByteArray(CHUNK + 16)
        out.write(aad)
        var total = 0L
        while (true) {
            if (cancelled()) throw IOException("Export cancelled")
            val n = input.read(buf)
            if (n < 0) break
            if (n == 0) continue
            sha.update(buf, 0, n)
            val m = cipher.update(buf, 0, n, enc, 0)
            ghash.update(enc, 0, m)
            out.write(enc, 0, m)
            total += n
            onBytes(total)
        }
        val tail = cipher.doFinal()
        if (tail.isNotEmpty()) { ghash.update(tail, 0, tail.size); out.write(tail) }
        out.write(ghash.tag())
        out.flush()
        return hex(sha.digest())
    }

    /**
     * Reads a whole OSBK file, checks its header is [aad], authenticates the tag and returns the
     * SHA-256 (hex) of the decrypted plaintext. Throws on any mismatch.
     */
    fun verify(input: InputStream, onBytes: (Long) -> Unit, cancelled: () -> Boolean): String {
        val header = ByteArray(aad.size)
        var got = 0
        while (got < header.size) {
            val n = input.read(header, got, header.size - got)
            if (n < 0) throw IOException("wrong passphrase, or this backup has been modified")
            got += n
        }
        if (!header.contentEquals(aad)) throw IOException("wrong passphrase, or this backup has been modified")
        val ghash = Ghash().apply { aad(this@OsbkGcm.aad) }
        val sha = MessageDigest.getInstance("SHA-256")
        val cipher = ctr(Cipher.DECRYPT_MODE)
        // The last 16 bytes are the tag: hold them back until the stream ends.
        val buf = ByteArray(CHUNK + 16)
        val plain = ByteArray(CHUNK + 32)
        var held = 0
        var total = header.size.toLong()
        while (true) {
            if (cancelled()) throw IOException("Export cancelled")
            val n = input.read(buf, held, CHUNK)
            if (n < 0) break
            if (n == 0) continue
            total += n
            val avail = held + n
            val body = avail - 16
            if (body > 0) {
                ghash.update(buf, 0, body)
                val m = cipher.update(buf, 0, body, plain, 0)
                sha.update(plain, 0, m)
                System.arraycopy(buf, body, buf, 0, 16)
                held = 16
            } else held = avail
            onBytes(total)
        }
        if (held < 16) throw IOException("wrong passphrase, or this backup has been modified")
        val tail = cipher.doFinal()
        if (tail.isNotEmpty()) sha.update(tail)
        val tag = ghash.tag()
        if (!MessageDigest.isEqual(tag, buf.copyOfRange(0, 16))) {
            throw IOException("wrong passphrase, or this backup has been modified")
        }
        return hex(sha.digest())
    }

    companion object {
        const val CHUNK = 1 shl 20
        private val LAST4 = longArrayOf(0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0,
            0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0)

        private fun be64(b: ByteArray, off: Int): Long {
            var v = 0L
            for (k in 0 until 8) v = (v shl 8) or (b[off + k].toLong() and 0xff)
            return v
        }

        private fun put64(b: ByteArray, off: Int, v: Long) {
            for (k in 0 until 8) b[off + k] = (v ushr ((7 - k) * 8)).toByte()
        }

        private fun hex(bytes: ByteArray): String {
            val digits = "0123456789abcdef"
            val sb = StringBuilder(bytes.size * 2)
            for (b in bytes) { val v = b.toInt() and 0xff; sb.append(digits[v ushr 4]).append(digits[v and 0xf]) }
            return sb.toString()
        }
    }
}
