package wtf.openstrap.openstrap_edge

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.math.BigInteger
import java.security.MessageDigest
import java.util.Random
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class OsbkGcmTest {
    private val rng = Random(7)
    private fun bytes(n: Int) = ByteArray(n).also { rng.nextBytes(it) }
    private val key = bytes(32)
    private val nonce = bytes(12)
    private val header = bytes(38)

    // Reads in odd-sized pieces so block carry-over paths run.
    private class Trickle(private val inner: InputStream, private val step: Int) : InputStream() {
        override fun read() = inner.read()
        override fun read(b: ByteArray, off: Int, len: Int) = inner.read(b, off, minOf(len, step))
    }

    private fun reference(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(header)
        return header + c.doFinal(plain)
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    @Test fun matchesStandardGcmAndVerifiesForManySizes() {
        for (size in listOf(0, 1, 15, 16, 17, 31, 4096, 70_001, OsbkGcm.CHUNK + 5, 2 * OsbkGcm.CHUNK + 33)) {
            for (step in listOf(7, 1 shl 16, Int.MAX_VALUE)) {
                val plain = bytes(size)
                val out = ByteArrayOutputStream()
                val hash = OsbkGcm(key, nonce, header).encrypt(Trickle(ByteArrayInputStream(plain), step), out, {}, { false })
                assertArrayEquals("size $size step $step", reference(plain), out.toByteArray())
                assertEquals(sha(plain), hash)
                val verified = OsbkGcm(key, nonce, header).verify(Trickle(ByteArrayInputStream(out.toByteArray()), step), {}, { false })
                assertEquals(sha(plain), verified)
            }
        }
    }

    @Test fun verifyRefusesTamperedTruncatedOrForeignFiles() {
        val file = reference(bytes(5000))
        for (index in listOf(0, 37, 38, 2000, file.size - 17, file.size - 1)) {
            val bad = file.copyOf().also { it[index] = (it[index].toInt() xor 1).toByte() }
            assertThrows(IOException::class.java) { OsbkGcm(key, nonce, header).verify(ByteArrayInputStream(bad), {}, { false }) }
        }
        assertThrows(IOException::class.java) { OsbkGcm(key, nonce, header).verify(ByteArrayInputStream(file.copyOf(file.size - 1)), {}, { false }) }
        assertThrows(IOException::class.java) { OsbkGcm(key, nonce, header).verify(ByteArrayInputStream(file.copyOf(20)), {}, { false }) }
        assertThrows(IOException::class.java) { OsbkGcm(bytes(32), nonce, header).verify(ByteArrayInputStream(file), {}, { false }) }
    }

    @Test fun cancellationStopsBothPasses() {
        val plain = bytes(3 * OsbkGcm.CHUNK)
        assertThrows(IOException::class.java) {
            OsbkGcm(key, nonce, header).encrypt(ByteArrayInputStream(plain), ByteArrayOutputStream(), {}, { true })
        }
        assertThrows(IOException::class.java) {
            OsbkGcm(key, nonce, header).verify(ByteArrayInputStream(reference(plain)), {}, { true })
        }
    }

    // [review r1 F6] The writer asks before every write, so a reserve spent mid-write stops it.
    @Test fun writerAsksBeforeEveryWriteAndStopsWhenRefused() {
        val plain = bytes(3 * OsbkGcm.CHUNK + 9)
        val asked = ArrayList<Long>()
        val out = ByteArrayOutputStream()
        OsbkGcm(key, nonce, header).encrypt(ByteArrayInputStream(plain), out, {}, { false }, { asked.add(it) })
        assertEquals("every byte written was asked for first", out.size().toLong(), asked.sum())

        var calls = 0
        val partial = ByteArrayOutputStream()
        assertThrows(IOException::class.java) {
            OsbkGcm(key, nonce, header).encrypt(ByteArrayInputStream(plain), partial, {}, { false }) {
                if (++calls == 3) throw IOException("no room")
            }
        }
        assertEquals("nothing is written after a refusal", header.size + OsbkGcm.CHUNK.toLong(), partial.size().toLong())
    }

    // [review r1 F7] pointycastle 3.9 keeps the ciphertext bit length in a Uint32. Expected values are
    // that arithmetic done independently (BigInteger), at, below and above the 2^29-byte wrap.
    @Test fun lengthWordWrapsLikePointycastleAround512MiB() {
        val wrap = BigInteger.ONE.shiftLeft(32)
        val m512 = 1L shl 29
        for (n in listOf(0L, 1L, 38L, m512 - 1, m512, m512 + 1, m512 + 17, 2 * m512 - 1, 2 * m512, (1L shl 32) + 5, 537_000_123L, 1L shl 40)) {
            val expected = BigInteger.valueOf(n).shiftLeft(3).mod(wrap).toLong()
            assertEquals("bytes $n", expected, OsbkGcm.lengthWord(n))
        }
        assertEquals(0xffff_fff8L, OsbkGcm.lengthWord(m512 - 1))
        assertEquals(0L, OsbkGcm.lengthWord(m512))
        assertEquals(136L, OsbkGcm.lengthWord(m512 + 17))
        assertEquals(40L, OsbkGcm.lengthWord((1L shl 32) + 5))
    }

    // The same 537,000,123 plaintext bytes (just over 512 MiB) as test/official_export/gcm_length_oracle_test.dart,
    // which has pointycastle encrypt them: its output hashes to ORACLE_SHA256 (recorded 2026-11-21). If the length
    // block drifts from pointycastle's, only this streamed vector notices at the real size.
    @Test fun streamedOracleAbove512MiBMatchesPointycastle() {
        val oracleKey = ByteArray(32) { it.toByte() }
        val oracleNonce = ByteArray(12) { (0xA0 + it).toByte() }
        val oracleHeader = ByteArray(38) { (0x40 + it).toByte() }
        val total = 537_000_123L
        val plain = object : InputStream() {
            private var x = 0x9E3779B97F4A7C15uL.toLong()
            private var left = total
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (left == 0L) return -1
                val n = minOf(len.toLong(), left).toInt()
                var s = x
                for (i in off until off + n) {
                    s = s xor (s shl 13); s = s xor (s ushr 7); s = s xor (s shl 17)
                    b[i] = (s ushr 56).toByte()
                }
                x = s; left -= n
                return n
            }
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val sink = object : java.io.OutputStream() {
            override fun write(b: Int) = digest.update(b.toByte())
            override fun write(b: ByteArray, off: Int, len: Int) = digest.update(b, off, len)
        }
        OsbkGcm(oracleKey, oracleNonce, oracleHeader).encrypt(plain, sink, {}, { false })
        assertEquals(ORACLE_SHA256, digest.digest().joinToString("") { "%02x".format(it) })
    }

    private companion object {
        const val ORACLE_SHA256 = "e80f1467cc408c3797d023c7e39a1bed69506b5dfd65273d6106bb6108f6892e"
    }
}
