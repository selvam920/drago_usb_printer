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
        /** Max chunk size for bulk transfers (16 KB) */
        private const val DEFAULT_CHUNK_SIZE = 16 * 1024
        /** Timeout per chunk in ms */
        private const val CHUNK_TIMEOUT_MS = 5000
        /** Max retries per chunk on transient failure */
        private const val MAX_RETRIES = 3
        /** Delay between retries in ms */
        private const val RETRY_DELAY_MS = 50L
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
     * Write data in chunks sized to the endpoint's max packet size (or DEFAULT_CHUNK_SIZE).
     * - Splits large payloads into manageable pieces to avoid USB transfer timeouts.
     * - Retries each chunk up to MAX_RETRIES on transient failures.
     * - Synchronized so concurrent writes don't interleave on the same connection.
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

            val chunkSize = resolveChunkSize(endpoint)
            var totalSent = 0
            var offset = 0

            while (offset < data.size) {
                val length = min(chunkSize, data.size - offset)
                val chunk = if (offset == 0 && length == data.size) {
                    data  // avoid copy when data fits in one chunk
                } else {
                    data.copyOfRange(offset, offset + length)
                }

                val sent = transferChunkWithRetry(connection, endpoint, chunk, length)
                totalSent += sent
                offset += length
            }
            return totalSent
        }
    }

    /**
     * Transfer a single chunk with retry logic.
     */
    private fun transferChunkWithRetry(
        connection: UsbDeviceConnection,
        endpoint: UsbEndpoint,
        chunk: ByteArray,
        length: Int
    ): Int {
        var lastError = -1
        for (attempt in 1..MAX_RETRIES) {
            val sent = connection.bulkTransfer(endpoint, chunk, length, CHUNK_TIMEOUT_MS)
            if (sent >= 0) {
                return sent
            }
            lastError = sent
            if (attempt < MAX_RETRIES) {
                Thread.sleep(RETRY_DELAY_MS)
            }
        }
        throw Exception(
            "USB bulk transfer failed after $MAX_RETRIES retries (error=$lastError, chunkSize=$length)"
        )
    }

    /**
     * Determine optimal chunk size: use a multiple of the endpoint's maxPacketSize,
     * capped at DEFAULT_CHUNK_SIZE.
     */
    private fun resolveChunkSize(endpoint: UsbEndpoint): Int {
        val maxPacket = endpoint.maxPacketSize
        return if (maxPacket > 0) {
            // Use the largest multiple of maxPacketSize that fits within DEFAULT_CHUNK_SIZE
            val multiplier = DEFAULT_CHUNK_SIZE / maxPacket
            if (multiplier > 0) multiplier * maxPacket else maxPacket
        } else {
            DEFAULT_CHUNK_SIZE
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