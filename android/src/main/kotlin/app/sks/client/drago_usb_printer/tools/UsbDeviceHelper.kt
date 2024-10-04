package app.sks.client.drago_usb_printer.tools

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.*
import android.os.Build

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

    companion object {
        val instance by lazy(LazyThreadSafetyMode.NONE) {
            UsbDeviceHelper()
        }
    }

    fun init(context: Context) {
        this.mContext = context
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            mPermissionIntent =
                PendingIntent.getActivity(context, 0,  Intent(UsbDeviceReceiver.Config.ACTION_USB_PERMISSION), PendingIntent.FLAG_MUTABLE)
        } else {
            mPermissionIntent =
                PendingIntent.getActivity(context, 0,  Intent(UsbDeviceReceiver.Config.ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE)
        }
        usbManager = context.applicationContext.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    fun setUsbListener(listener: OnUsbListener) {
        usbDeviceReceiver.setUsbListener(listener)
    }

    fun queryLocalPrinterMap(): List<HashMap<String, Any?>> {

        val resultData = arrayListOf<HashMap<String, Any?>>()
        val deviceList = queryPrinterDevices()
        for (index in deviceList.indices) {
            val item = deviceList[index]
            checkPermission(item)?.let { hasPermission ->
                if (hasPermission) {
                    val deviceMap = HashMap<String, Any?>()
                    deviceMap["deviceName"] = item.deviceName
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        deviceMap["manufacturer"] = item.manufacturerName
                    }else{
                        deviceMap["manufacturer"] = "unknown";
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        deviceMap["productName"] = item.productName
                    }else{
                        deviceMap["productName"] = "unknown";
                    }
                    deviceMap["deviceId"] = item.deviceId.toString()
                    deviceMap["vendorId"] = Integer.toString(item.vendorId)
                    deviceMap["productId"] = Integer.toString(item.productId)

                    resultData.add(deviceMap)
                }
            }
        }
        return resultData
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
