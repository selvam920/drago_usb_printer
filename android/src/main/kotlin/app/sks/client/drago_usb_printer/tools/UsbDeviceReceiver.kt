package app.sks.client.drago_usb_printer.tools

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build

/**
 * @Description:    监听USB插拔、USB设备授权
 * @Author:         liyufeng
 * @CreateDate:     2022/2/18 10:42 上午
 */

class UsbDeviceReceiver : BroadcastReceiver() {

    object Config {
        const val ACTION_USB_PERMISSION = "app.sks.client.drago_usb_printer.USB_PERMISSION"
    }

    private var usbListener: OnUsbListener? = null

    override fun onReceive(context: Context, intent: Intent) {
        when {
            Config.ACTION_USB_PERMISSION == intent.action -> {
                synchronized(this) {
                    val usbDevice = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    usbDevice?.let { device ->
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        // Notify UsbDeviceHelper to resolve any pending coroutine awaiting permission
                        UsbDeviceHelper.instance.onPermissionResult(device, granted)
                        usbListener?.onDeviceGranted(device, granted)
                    }
                }
            }
            UsbManager.ACTION_USB_DEVICE_DETACHED == intent.action -> {
                val usbDevice = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                usbListener?.onDeviceDetached(usbDevice)
            }
            UsbManager.ACTION_USB_DEVICE_ATTACHED == intent.action -> {
                val usbDevice = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                usbListener?.onDeviceAttached(usbDevice)
            }
        }
    }

    fun setUsbListener(listener: OnUsbListener) {
        this.usbListener = listener
    }

    /**
     * 注册广播
     */
    fun registerUsbReceiver(context: Context) {
        val filter = IntentFilter(Config.ACTION_USB_PERMISSION)
        filter.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        filter.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(this, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(this, filter)
        }
    }

    /**
     * 取消注册
     */
    fun unRegisterUsbReceiver(context: Context) {
        context.unregisterReceiver(this)
    }
}

interface OnUsbListener {
    fun onDeviceAttached(usbDevice: UsbDevice?) //usb插入
    fun onDeviceDetached(usbDevice: UsbDevice?) //usb拔出
    fun onDeviceGranted(usbDevice: UsbDevice, success: Boolean) //usb设备授权
}