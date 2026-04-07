package app.sks.client.drago_usb_printer

import android.hardware.usb.*
import android.os.SystemClock
import app.sks.client.drago_usb_printer.tools.UsbDeviceHelper
import kotlin.math.min


/// Author       : liyufeng
/// Date         : 14:42
/// Description  : 
class UsbConn(private val mUsbDevice: UsbDevice) {

    var isConn = false

    private val mLock = Any()
    private val mWriteLock = Any()
    private var mConnection: UsbDeviceConnection? = null
    private var mUsbInterface: UsbInterface? = null

    //块传输模式
    private var mBulkEndIn: UsbEndpoint? = null
    private var mBulkEndOut: UsbEndpoint? = null

    //中断传输模式
    private var mInterruptEndIn: UsbEndpoint? = null
    private var mInterruptEndOut: UsbEndpoint? = null

    companion object {
        /** Initial chunk size — will be halved automatically on transfer failures */
        private const val INITIAL_CHUNK_SIZE = 8 * 1024
        /** Minimum chunk size before giving up */
        private const val MIN_CHUNK_SIZE = 512
        /** Timeout per chunk in ms */
        private const val CHUNK_TIMEOUT_MS = 8000
        /** Max retries per chunk at any given chunk-size level */
        private const val MAX_RETRIES = 3
        /** Delay between retries in ms */
        private const val RETRY_DELAY_MS = 100L
        /** Throttle delay applied only after a chunk needed retries */
        private const val BACKPRESSURE_DELAY_MS = 20L
    }

    private fun checkConnAndReConnect(): Boolean {
        if (!isConn) {
            connect()
        }
        return isConn
    }

    fun connect(): Boolean {
        openPort()
        isConn = mBulkEndOut != null && mBulkEndIn != null
        return isConn
    }

    private fun openPort() {
        val count = mUsbDevice.interfaceCount
        var usbInf: UsbInterface? = null
        for (index in 0 until count) {
            val usbInterface = mUsbDevice.getInterface(index)
            if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                usbInf = usbInterface
            }
        }
        usbInf?.let {
            mUsbInterface = usbInf
            mConnection = UsbDeviceHelper.instance.openDevice(mUsbDevice)
            if (!mConnection!!.claimInterface(usbInf, true)) {
                return
            }
            for (i in 0 until usbInf.endpointCount) {
                val ep = usbInf.getEndpoint(i)
                when (ep.type) {
                    UsbConstants.USB_ENDPOINT_XFER_BULK ->
                        //usb 块传输
                        if (ep.direction == UsbConstants.USB_DIR_OUT) {
                            mBulkEndOut = ep
                        } else {
                            mBulkEndIn = ep
                        }
                    UsbConstants.USB_ENDPOINT_XFER_INT -> {
                        //usb 中断传输
                        if (ep.direction == UsbConstants.USB_DIR_OUT) {
                            mInterruptEndOut = ep
                        }
                        if (ep.direction == UsbConstants.USB_DIR_IN) {
                            mInterruptEndIn = ep
                        }
                    }
                }
            }
        }
    }

    fun disconnect(): Boolean {
        synchronized(mLock) {
            if (!isConn) {
                return true
            }
            try {
                mUsbInterface?.let {
                    mConnection?.releaseInterface(it)
                    mConnection?.close()
                }
            } catch (e: Exception) {
                //暂无处理
            } finally {
                mConnection = null
                isConn = false
            }
        }
        return true
    }

    /**
     * Write data using adaptive chunking for large payloads (e.g. barcode images).
     *
     * - Uses offset-based bulkTransfer to avoid allocating a byte-array copy per chunk.
     * - Starts with a larger chunk size for throughput; automatically halves it on
     *   repeated failures so slow printers still work.
     * - Only applies back-pressure delay after a chunk required retries.
     *
     * @return total number of bytes successfully transferred
     * @throws Exception on unrecoverable write failure
     */
    fun writeBytes(data: ByteArray): Int {
        if (!checkConnAndReConnect()) {
            throw Exception("Printer not connected")
        }
        synchronized(mWriteLock) {
            val connection = mConnection
                ?: throw Exception("USB connection lost")
            val endpoint = mBulkEndOut
                ?: throw Exception("Bulk OUT endpoint not available")

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
                        // Only throttle when the chunk needed retries (printer is under pressure)
                        if (result.retriesUsed > 0 && offset < data.size) {
                            Thread.sleep(BACKPRESSURE_DELAY_MS)
                        }
                    }
                    result.shouldReduceChunk && chunkSize > MIN_CHUNK_SIZE -> {
                        // Halve the chunk size and retry from the same offset
                        chunkSize = (chunkSize / 2).coerceAtLeast(MIN_CHUNK_SIZE)
                        Thread.sleep(RETRY_DELAY_MS)
                    }
                    else -> {
                        throw Exception(
                            "USB bulk transfer failed " +
                            "(error=${result.lastError}, chunkSize=$length, " +
                            "offset=$offset, totalSize=${data.size}, " +
                            "endpointMaxPacket=${endpoint.maxPacketSize})"
                        )
                    }
                }
            }
            return totalSent
        }
    }

    private data class ChunkResult(
        val sent: Int,
        val retriesUsed: Int,
        val lastError: Int,
        val shouldReduceChunk: Boolean
    )

    /**
     * Try to send a single chunk. Returns a result indicating success/failure
     * so the caller can decide whether to reduce chunk size or abort.
     */
    private fun transferChunkAdaptive(
        connection: UsbDeviceConnection,
        endpoint: UsbEndpoint,
        data: ByteArray,
        offset: Int,
        length: Int
    ): ChunkResult {
        var lastError = -1
        for (attempt in 1..MAX_RETRIES) {
            val sent = connection.bulkTransfer(endpoint, data, offset, length, CHUNK_TIMEOUT_MS)
            if (sent >= 0) {
                return ChunkResult(sent = sent, retriesUsed = attempt - 1, lastError = 0, shouldReduceChunk = false)
            }
            lastError = sent
            if (attempt < MAX_RETRIES) {
                Thread.sleep(RETRY_DELAY_MS)
            }
        }
        // All retries exhausted — signal caller to try a smaller chunk
        return ChunkResult(sent = 0, retriesUsed = MAX_RETRIES, lastError = lastError, shouldReduceChunk = true)
    }

    /**
     * Determine initial chunk size: largest multiple of endpoint maxPacketSize
     * that fits within INITIAL_CHUNK_SIZE.
     */
    private fun resolveChunkSize(endpoint: UsbEndpoint): Int {
        val maxPacket = endpoint.maxPacketSize
        return if (maxPacket > 0) {
            val multiplier = INITIAL_CHUNK_SIZE / maxPacket
            if (multiplier > 0) multiplier * maxPacket else maxPacket
        } else {
            INITIAL_CHUNK_SIZE
        }
    }

    fun readBytes(timeOut: Int): ByteArray? {
        if (!checkConnAndReConnect()) {
            throw Exception("Printer not connected")
        }
        val connection = mConnection
            ?: throw Exception("USB connection lost")
        val endpointIn = mBulkEndIn
            ?: throw Exception("Bulk IN endpoint not available")

        val endTime = SystemClock.uptimeMillis() + timeOut.toLong()
        val buffer = ByteArray(endpointIn.maxPacketSize.coerceAtLeast(64))
        do {
            val len = connection.bulkTransfer(endpointIn, buffer, buffer.size, timeOut)
            if (len > 0) {
                return buffer.copyOf(len)
            }
            try {
                Thread.sleep(100L)
            } catch (_: InterruptedException) {
                // interrupted, retry
            }
        } while (endTime > SystemClock.uptimeMillis())
        return null
    }

}