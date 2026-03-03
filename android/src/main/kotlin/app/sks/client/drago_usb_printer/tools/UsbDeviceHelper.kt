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
        val instance by lazy(LazyThreadSafetyMode.NONE) {
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
        var isFit = false
        val count: Int = usbDevice.interfaceCount
        for (index in 0 until count) {
            val usbInterface: UsbInterface = usbDevice.getInterface(index)
            if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                isFit = true
                break
            }
        }
        return isFit
    }

    //根据 vId、pId、sId 匹配 usbDevice
    fun matchUsbDevice(vendorId: Int, productId: Int): UsbDevice? {
        var usbDevice: UsbDevice? = null
        val deviceList = queryPrinterDevices()
        val hitDevices = arrayListOf<UsbDevice>()

        deviceList.forEach { e ->
            checkPermission(e)?.let { hasPermission ->
                if (hasPermission) {
                    if (e.vendorId == vendorId && e.productId == productId) {
                        hitDevices.add(e)
                    }
                }
            }
        }

        if (hitDevices.isNotEmpty()) {
            usbDevice = hitDevices.first()
        }
        return usbDevice
    }

    fun openDevice(usbDevice: UsbDevice): UsbDeviceConnection {
        return usbManager.openDevice(usbDevice)
    }

    fun requestPermission(usbDevice: UsbDevice) {
        usbManager.requestPermission(usbDevice, mPermissionIntent)
    }

    fun hasPermission(usbDevice: UsbDevice): Boolean {
        return usbManager.hasPermission(usbDevice)
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
        val deferred = CompletableDeferred<Boolean>()
        pendingPermissions[key] = deferred

        usbManager.requestPermission(usbDevice, mPermissionIntent)

        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } catch (e: Exception) {
            false
        } finally {
            pendingPermissions.remove(key)
        }
    }

    /**
     * Called by UsbDeviceReceiver when a permission dialog result is received.
     */
    fun onPermissionResult(usbDevice: UsbDevice, granted: Boolean) {
        val key = "${usbDevice.vendorId}-${usbDevice.productId}"
        pendingPermissions[key]?.complete(granted)
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
