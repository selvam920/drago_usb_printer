package app.sks.client.drago_usb_printer

import android.hardware.usb.UsbDevice
import android.util.Base64
import app.sks.client.drago_usb_printer.tools.MessageSender
import app.sks.client.drago_usb_printer.tools.MethodCallParser
import app.sks.client.drago_usb_printer.tools.OnUsbListener
import app.sks.client.drago_usb_printer.tools.UsbDeviceHelper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.charset.Charset

/** DragoUsbPrinterPlugin */
class DragoUsbPrinterPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var binaryMessenger: BinaryMessenger
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel

  private lateinit var usbConnCache: HashMap<String, UsbConn>
  private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  companion object {
    private const val ERROR_USB = "USB device not found or not accessible"
    private const val ERROR_CODE = "-1"
  }

  private val usbBroadListener = object : OnUsbListener {
    override fun onDeviceAttached(usbDevice: UsbDevice?) {
      //Usb设备插入
      usbDevice?.let {
        UsbDeviceHelper.instance.checkPermission(it)?.let { hasPermission ->
          if (hasPermission) {
            MessageSender.sendUsbPlugStatus(usbDevice, 1)
          }
        }
      }
    }

    override fun onDeviceDetached(usbDevice: UsbDevice?) {
      //Usb设备拔出
      usbDevice?.let {
        val deviceId = "${it.vendorId} - ${it.productId}"
        removeConnCacheWithKey(deviceId)
        MessageSender.sendUsbPlugStatus(usbDevice, 0)
      }
    }

    override fun onDeviceGranted(usbDevice: UsbDevice, success: Boolean) {
      //Usb设备授权
      if (success) {
        MessageSender.sendUsbPlugStatus(usbDevice, 2)
      }
    }
  }

  private fun onUsbBroadListen() {
    UsbDeviceHelper.instance.setUsbListener(usbBroadListener)
    UsbDeviceHelper.instance.registerUsbReceiver(MessageSender.applicationContext)
  }

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    MessageSender.applicationContext = flutterPluginBinding.applicationContext
    this.binaryMessenger = flutterPluginBinding.binaryMessenger
    channel = MethodChannel(
      binaryMessenger,
      "drago_usb_printer"
    )
    eventChannel =
      EventChannel(binaryMessenger, "drago_usb_printer_event_channel")
    channel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)

    usbConnCache = HashMap()
    UsbDeviceHelper.instance.init(flutterPluginBinding.applicationContext)
    onUsbBroadListen()
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getUSBDeviceList" -> {
        pluginScope.launch {
          try {
            val devices = UsbDeviceHelper.instance.queryLocalPrinterMapAsync()
            result.success(devices)
          } catch (e: Exception) {
            result.error(ERROR_CODE, e.message ?: "Failed to get device list", null)
          }
        }
      }
      "printText" -> {
        val text = call.argument<String?>("text")
        if(text != null) {
          val data = text.toByteArray(Charset.forName("UTF-8"))
          write(call, data, result)
        }
      }
      "printRawText" -> {
        val raw = call.argument<String>("raw")
        val data = Base64.decode(raw, Base64.DEFAULT)
        data?.let { write(call, it,  result) }
      }
      "write" -> {
        val data = call.argument<ByteArray>("data")
        if(data != null) write(call, data,  result) else result.success(false)
      }
      "checkDeviceConn" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) {
          val usbDevice = device.usbDevice
          val deviceId = device.deviceId
          if (!usbConnCache.containsKey(deviceId)) {
            usbConnCache[deviceId] = UsbConn(usbDevice)
          }
          result.success(usbConnCache[deviceId]!!.isConn)
        } else {
          result.error(ERROR_CODE, ERROR_USB, null)
        }
      }
      "connect" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) {
          val usbDevice = device.usbDevice
          val deviceId = device.deviceId
          if (!usbConnCache.containsKey(deviceId)) {
            usbConnCache[deviceId] = UsbConn(usbDevice)
          }
          try {
            val connected = usbConnCache[deviceId]!!.connect()
            result.success(connected)
          } catch (e: Exception) {
            result.error(ERROR_CODE, e.message ?: "Connection failed", null)
          }
        } else {
          result.error(ERROR_CODE, ERROR_USB, null)
        }
      }
      "disconnect" -> {
        val deviceId = MethodCallParser.parseDeviceId(call)
        if (usbConnCache.containsKey(deviceId)) {
          usbConnCache[deviceId]!!.disconnect()
          usbConnCache.remove(deviceId)
          result.success(true)
        } else {
          result.error(ERROR_CODE, ERROR_USB, null)
        }
      }
      "checkDevicePermission" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) {
          result.success(UsbDeviceHelper.instance.hasPermission(device.usbDevice))
        } else {
          result.error(ERROR_CODE, ERROR_USB, null)
        }
      }
      "requestDevicePermission" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) {
          UsbDeviceHelper.instance.requestPermission(device.usbDevice)
          result.success(true)
        } else {
          result.error(ERROR_CODE, ERROR_USB, null)
        }
      }
      "removeUsbConnCache" -> {
        val deviceId = MethodCallParser.parseDeviceId(call)
        removeConnCacheWithKey(deviceId)
        result.success(true)
      }
    }
  }
  
  private fun write(call: MethodCall, bytes: ByteArray, result: Result) {
    val usbConn = fetchUsbConn(call)
    if (usbConn != null) {
      pluginScope.launch {
        try {
          withContext(Dispatchers.IO) {
            usbConn.writeBytes(bytes)
          }
          result.success(true)
        } catch (e: Exception) {
          result.error(ERROR_CODE, e.message ?: "Write failed", null)
        }
      }
    } else {
      result.error(ERROR_CODE, ERROR_USB, null)
    }
  }

  private fun fetchUsbConn(call: MethodCall): UsbConn? {
    val deviceId = MethodCallParser.parseDeviceId(call)
    if (!usbConnCache.containsKey(deviceId)) {
      val device = MethodCallParser.parseDevice(call)
      if (device != null) {
        usbConnCache[deviceId] = UsbConn(device.usbDevice)
      }
    }
    return usbConnCache[deviceId]
  }

  private fun removeConnCacheWithKey(key: String) {
    val removeCaches = arrayListOf<String>()
    usbConnCache.keys.forEach {
      if (it.contains(key)) {
        removeCaches.add(it)
      }
    }
    if (removeCaches.isNotEmpty()) {
      removeCaches.forEach {
        usbConnCache.remove(it)
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    pluginScope.cancel()
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    UsbDeviceHelper.instance.unRegisterUsbReceiver(binding.applicationContext)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    MessageSender.eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    //暂无处理
  }
}
