package app.sks.client.drago_usb_printer.tools

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.*
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap

/**
 * @Description:    usb设备工具
 * @Author:         liyufeng
 * @CreateDate:     2022/3/18 10:36 上午
 */

class UsbDeviceHelper private constructor() {

    private lateinit var mContext: Context
    private val usbDeviceReceiver: UsbDeviceReceiver = UsbDeviceReceiver()
    private lateinit var mPermissionIntent: PendingIntent
    private lateinit var usbManager: UsbManager
    private val pendingPermissions = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()

    companion object {
        val instance by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
            UsbDeviceHelper()
        }
        private const val PERMISSION_TIMEOUT_MS = 60000L
    }

    fun init(context: Context) {
        this.mContext = context
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

        val permissionIntent = Intent(UsbDeviceReceiver.Config.ACTION_USB_PERMISSION).apply {
            setPackage(context.packageName)
        }
        mPermissionIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.getBroadcast(
                context, 0,
                permissionIntent,
                PendingIntent.FLAG_MUTABLE
            )
        } else {
            PendingIntent.getBroadcast(
                context, 0,
                permissionIntent,
                PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    fun setUsbListener(listener: OnUsbListener) {
        usbDeviceReceiver.setUsbListener(listener)
    }

    /**
     * Query printer devices and wait for user to grant permission on each device.
     * Permission dialogs are shown sequentially (Android shows one at a time).
     * Returns only the devices the user granted permission to.
     */
    suspend fun queryLocalPrinterMapAsync(): List<HashMap<String, Any?>> {
        val resultData = arrayListOf<HashMap<String, Any?>>()
        val deviceList = queryPrinterDevices()
        for (device in deviceList) {
            val granted = requestPermissionAndWait(device)
            if (granted) {
                resultData.add(buildDeviceMap(device))
            }
        }
        return resultData
    }

    /**
     * Query printer devices - only returns devices that already have permission (non-blocking).
     */
    fun queryLocalPrinterMap(): List<HashMap<String, Any?>> {
        val resultData = arrayListOf<HashMap<String, Any?>>()
        val deviceList = queryPrinterDevices()
        for (device in deviceList) {
            if (hasPermission(device)) {
                resultData.add(buildDeviceMap(device))
            }
        }
        return resultData
    }

    private fun buildDeviceMap(device: UsbDevice): HashMap<String, Any?> {
        return hashMapOf(
            "deviceName" to device.deviceName,
            "manufacturer" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                device.manufacturerName
            } else {
                "unknown"
            },
            "productName" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                device.productName
            } else {
                "unknown"
            },
            "deviceId" to device.deviceId.toString(),
            "vendorId" to device.vendorId.toString(),
            "productId" to device.productId.toString()
        )
    }

    /**
     * 获取打印机设备
     */
    private fun queryPrinterDevices(): ArrayList<UsbDevice> {
        val devices = arrayListOf<UsbDevice>()
        val deviceList = usbManager.deviceList
        val deviceIterator: Iterator<UsbDevice> = deviceList.values.iterator()
        while (deviceIterator.hasNext()) {
            val device = deviceIterator.next()
            if (filterPrintUsbDevice(device)) {
                devices.add(device)
            }
        }
        return devices
    }

    //过滤打印机类型的Usb设备
    private fun filterPrintUsbDevice(usbDevice: UsbDevice): Boolean {
        // Printer class, or a vendor-specific/other interface with a bulk OUT
        // endpoint (many cheap thermal/label printers report class 0xFF).
        // Mass storage, HID, hubs, audio/video are excluded in pickInterface.
        return try {
            app.sks.client.drago_usb_printer.UsbConn.pickInterface(usbDevice) != null
        } catch (e: Exception) {
            false
        }
    }

    /** Attached device matching vId/pId (permitted or not); permitted ones win. */
    fun matchUsbDevice(vendorId: Int, productId: Int): UsbDevice? {
        val hits = usbManager.deviceList.values.filter {
            it.vendorId == vendorId && it.productId == productId
        }
        return hits.firstOrNull { hasPermission(it) } ?: hits.firstOrNull()
    }

    /** UsbManager.openDevice may return null (no permission, device gone). */
    fun openDevice(usbDevice: UsbDevice): UsbDeviceConnection? {
        return try {
            usbManager.openDevice(usbDevice)
        } catch (e: Exception) {
            null
        }
    }

    fun requestPermission(usbDevice: UsbDevice) {
        try {
            usbManager.requestPermission(usbDevice, mPermissionIntent)
        } catch (_: Exception) {
        }
    }

    fun hasPermission(usbDevice: UsbDevice): Boolean {
        return try {
            usbManager.hasPermission(usbDevice)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Request permission for a USB device and suspend until the user responds.
     * Returns true if permission was granted, false if denied or timed out.
     */
    suspend fun requestPermissionAndWait(
        usbDevice: UsbDevice,
        timeoutMs: Long = PERMISSION_TIMEOUT_MS
    ): Boolean {
        if (hasPermission(usbDevice)) return true

        val key = "${usbDevice.vendorId}-${usbDevice.productId}"
        // Join an in-flight request for the same device instead of replacing it
        // (replacing would leave the first caller waiting until timeout).
        var created = false
        val deferred = pendingPermissions.getOrPut(key) {
            created = true
            CompletableDeferred()
        }
        if (created) {
            try {
                usbManager.requestPermission(usbDevice, mPermissionIntent)
            } catch (e: Exception) {
                pendingPermissions.remove(key)
                return false
            }
        }

        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } catch (e: Exception) {
            false
        } finally {
            if (created) pendingPermissions.remove(key)
        }
    }

    /**
     * Called by UsbDeviceReceiver when a permission dialog result is received.
     */
    fun onPermissionResult(usbDevice: UsbDevice, granted: Boolean) {
        val key = "${usbDevice.vendorId}-${usbDevice.productId}"
        // Re-check with UsbManager: the receiver is exported, so the extra alone is not trusted.
        pendingPermissions[key]?.complete(granted && hasPermission(usbDevice))
    }

    //校验申请usb设备权限
    fun checkPermission(usbDevice: UsbDevice): Boolean? {
        return if (!hasPermission(usbDevice)) {
            requestPermission(usbDevice)
            null
        } else {
            true
        }
    }

    fun registerUsbReceiver(context: Context) {
        usbDeviceReceiver.registerUsbReceiver(context)
    }

    fun unRegisterUsbReceiver(context: Context) {
        usbDeviceReceiver.unRegisterUsbReceiver(context)
    }

}
