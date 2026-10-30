package app.sks.client.drago_usb_printer

import android.hardware.usb.*
import android.os.SystemClock
import app.sks.client.drago_usb_printer.tools.UsbDeviceHelper
import kotlin.math.min

/**
 * One open connection to a USB printer. All state changes and transfers go
 * through [mLock] so a disconnect cannot close the connection under a running
 * transfer.
 */
class UsbConn(private val mUsbDevice: UsbDevice) {

    @Volatile
    var isConn = false
        private set

    private val mLock = Any()
    private var mConnection: UsbDeviceConnection? = null
    private var mUsbInterface: UsbInterface? = null
    private var mBulkEndIn: UsbEndpoint? = null
    private var mBulkEndOut: UsbEndpoint? = null

    val device: UsbDevice get() = mUsbDevice

    companion object {
        private const val INITIAL_CHUNK_SIZE = 8 * 1024
        private const val MIN_CHUNK_SIZE = 512
        private const val CHUNK_TIMEOUT_MS = 8000
        private const val MAX_RETRIES = 3
        private const val RETRY_DELAY_MS = 100L
        private const val BACKPRESSURE_DELAY_MS = 20L

        private fun endpoint(inf: UsbInterface, dir: Int): UsbEndpoint? =
            (0 until inf.endpointCount).map { inf.getEndpoint(it) }.firstOrNull {
                it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == dir
            }

        private fun isExcludedClass(c: Int): Boolean =
            c == UsbConstants.USB_CLASS_MASS_STORAGE ||
                c == UsbConstants.USB_CLASS_HID ||
                c == UsbConstants.USB_CLASS_HUB ||
                c == UsbConstants.USB_CLASS_AUDIO ||
                c == UsbConstants.USB_CLASS_VIDEO ||
                c == UsbConstants.USB_CLASS_WIRELESS_CONTROLLER

        /** Printer-class interface with bulk OUT first, else any non-excluded interface with bulk OUT. */
        fun pickInterface(device: UsbDevice): UsbInterface? {
            val all = (0 until device.interfaceCount).map { device.getInterface(it) }
            return all.firstOrNull {
                it.interfaceClass == UsbConstants.USB_CLASS_PRINTER &&
                    endpoint(it, UsbConstants.USB_DIR_OUT) != null
            } ?: all.firstOrNull {
                !isExcludedClass(it.interfaceClass) && endpoint(it, UsbConstants.USB_DIR_OUT) != null
            }
        }
    }

    /** Opens (or re-opens) the device. Only a bulk OUT endpoint is required. */
    fun connect(): Boolean = synchronized(mLock) { connectLocked() }

    private fun connectLocked(): Boolean {
        if (isConn && mConnection != null) return true
        closeLocked()
        val inf = pickInterface(mUsbDevice) ?: return false
        val conn = UsbDeviceHelper.instance.openDevice(mUsbDevice) ?: return false
        val claimed = try {
            conn.claimInterface(inf, true)
        } catch (e: Exception) {
            false
        }
        if (!claimed) {
            try { conn.close() } catch (_: Exception) {}
            return false
        }
        mConnection = conn
        mUsbInterface = inf
        mBulkEndOut = endpoint(inf, UsbConstants.USB_DIR_OUT)
        mBulkEndIn = endpoint(inf, UsbConstants.USB_DIR_IN)
        isConn = mBulkEndOut != null
        if (!isConn) closeLocked()
        return isConn
    }

    private fun closeLocked() {
        val conn = mConnection
        val inf = mUsbInterface
        try {
            if (conn != null && inf != null) conn.releaseInterface(inf)
        } catch (_: Exception) {
        }
        try {
            conn?.close()
        } catch (_: Exception) {
        }
        mConnection = null
        mUsbInterface = null
        mBulkEndIn = null
        mBulkEndOut = null
        isConn = false
    }

    fun disconnect(): Boolean {
        synchronized(mLock) { closeLocked() }
        return true
    }

    /** Adaptive chunked write. Returns bytes sent; throws on unrecoverable failure. */
    fun writeBytes(data: ByteArray): Int = synchronized(mLock) { writeLocked(data) }

    private fun writeLocked(data: ByteArray): Int {
        if (!connectLocked()) throw Exception("Printer not connected")
        val connection = mConnection ?: throw Exception("USB connection lost")
        val endpoint = mBulkEndOut ?: throw Exception("Bulk OUT endpoint not available")

        var chunkSize = resolveChunkSize(endpoint)
        var totalSent = 0
        var offset = 0
        while (offset < data.size) {
            val length = min(chunkSize, data.size - offset)
            val result = transferChunkAdaptive(connection, endpoint, data, offset, length)
            when {
                result.sent > 0 -> {
                    totalSent += result.sent
                    offset += result.sent
                    if (result.retriesUsed > 0 && offset < data.size) Thread.sleep(BACKPRESSURE_DELAY_MS)
                }
                result.shouldReduceChunk && chunkSize > MIN_CHUNK_SIZE -> {
                    chunkSize = (chunkSize / 2).coerceAtLeast(MIN_CHUNK_SIZE)
                    Thread.sleep(RETRY_DELAY_MS)
                }
                else -> {
                    // Probably detached or stalled: drop the connection so the next
                    // call re-opens it cleanly instead of reusing a dead handle.
                    closeLocked()
                    throw Exception(
                        "USB bulk transfer failed (error=${result.lastError}, chunkSize=$length, " +
                            "offset=$offset, totalSize=${data.size}, endpointMaxPacket=${endpoint.maxPacketSize})"
                    )
                }
            }
        }
        return totalSent
    }

    private data class ChunkResult(val sent: Int, val retriesUsed: Int, val lastError: Int, val shouldReduceChunk: Boolean)

    private fun transferChunkAdaptive(
        connection: UsbDeviceConnection, endpoint: UsbEndpoint, data: ByteArray, offset: Int, length: Int
    ): ChunkResult {
        var lastError = -1
        for (attempt in 1..MAX_RETRIES) {
            // 0 counts as failure: accepting it would loop forever at the same offset.
            val sent = connection.bulkTransfer(endpoint, data, offset, length, CHUNK_TIMEOUT_MS)
            if (sent > 0) return ChunkResult(sent, attempt - 1, 0, false)
            lastError = sent
            if (attempt < MAX_RETRIES) Thread.sleep(RETRY_DELAY_MS)
        }
        return ChunkResult(0, MAX_RETRIES, lastError, true)
    }

    private fun resolveChunkSize(endpoint: UsbEndpoint): Int {
        val maxPacket = endpoint.maxPacketSize
        return if (maxPacket > 0) {
            val multiplier = INITIAL_CHUNK_SIZE / maxPacket
            if (multiplier > 0) multiplier * maxPacket else maxPacket
        } else INITIAL_CHUNK_SIZE
    }

    /**
     * Writes [query] then waits up to [timeOut] ms for a reply on the bulk IN
     * endpoint. Returns null when there is no IN endpoint, no connection, or no reply.
     */
    fun query(query: ByteArray, timeOut: Int): ByteArray? = synchronized(mLock) {
        if (!connectLocked()) return null
        val conn = mConnection ?: return null
        val ep = mBulkEndIn ?: return null
        // Drain stale bytes from an earlier reply (bounded).
        val junk = ByteArray(ep.maxPacketSize.coerceAtLeast(64))
        var guard = 0
        while (guard++ < 16 && conn.bulkTransfer(ep, junk, junk.size, 10) > 0) { }
        if (query.isNotEmpty()) writeLocked(query)
        readLocked(timeOut)
    }

    fun readBytes(timeOut: Int): ByteArray? = synchronized(mLock) {
        if (!connectLocked()) return null
        readLocked(timeOut)
    }

    private fun readLocked(timeOut: Int): ByteArray? {
        val connection = mConnection ?: return null
        val endpointIn = mBulkEndIn ?: return null
        val endTime = SystemClock.uptimeMillis() + timeOut.toLong()
        val buffer = ByteArray(endpointIn.maxPacketSize.coerceAtLeast(64))
        do {
            val remaining = (endTime - SystemClock.uptimeMillis()).toInt().coerceAtLeast(1)
            val len = connection.bulkTransfer(endpointIn, buffer, buffer.size, remaining)
            if (len > 0) return buffer.copyOf(len)
            Thread.sleep(20L)
        } while (endTime > SystemClock.uptimeMillis())
        return null
    }
}
