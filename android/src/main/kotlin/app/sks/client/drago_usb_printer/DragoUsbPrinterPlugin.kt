package app.sks.client.drago_usb_printer

import android.hardware.usb.UsbDevice
import android.util.Base64
import app.sks.client.drago_usb_printer.tools.MessageSender
import app.sks.client.drago_usb_printer.tools.MethodCallParser
import app.sks.client.drago_usb_printer.tools.OnUsbListener
import app.sks.client.drago_usb_printer.tools.UsbDeviceHelper
import io.flutter.embedding.engine.plugins.FlutterPlugin
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
import java.util.concurrent.ConcurrentHashMap

/** DragoUsbPrinterPlugin */
class DragoUsbPrinterPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel

  private val usbConnCache = ConcurrentHashMap<String, UsbConn>()
  private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  companion object {
    private const val ERROR_USB = "USB device not found or not accessible"
    private const val ERROR_PERMISSION = "USB permission denied"
    private const val ERROR_CODE = "-1"
  }

  private val usbBroadListener = object : OnUsbListener {
    override fun onDeviceAttached(usbDevice: UsbDevice?) {
      usbDevice?.let {
        // Only report; don't pop a permission dialog for every plugged device.
        if (UsbDeviceHelper.instance.hasPermission(it)) MessageSender.sendUsbPlugStatus(it, 1)
      }
    }

    override fun onDeviceDetached(usbDevice: UsbDevice?) {
      usbDevice?.let {
        removeConnCacheWithKey(deviceKey(it.vendorId, it.productId))
        MessageSender.sendUsbPlugStatus(it, 0)
      }
    }

    override fun onDeviceGranted(usbDevice: UsbDevice, success: Boolean) {
      if (success) MessageSender.sendUsbPlugStatus(usbDevice, 2)
    }
  }

  private fun deviceKey(vendorId: Int?, productId: Int?) = "$vendorId - $productId"

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    MessageSender.applicationContext = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "drago_usb_printer")
    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "drago_usb_printer_event_channel")
    channel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)

    UsbDeviceHelper.instance.init(flutterPluginBinding.applicationContext)
    UsbDeviceHelper.instance.setUsbListener(usbBroadListener)
    UsbDeviceHelper.instance.registerUsbReceiver(flutterPluginBinding.applicationContext)
  }

  /**
   * Every branch replies exactly once. Blocking USB work runs on IO; replies are
   * delivered on Main (pluginScope dispatcher).
   */
  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getUSBDeviceList" -> launchReply(result, "Failed to get device list") {
        UsbDeviceHelper.instance.queryLocalPrinterMapAsync()
      }
      "printText" -> {
        val text = call.argument<String>("text")
        if (text == null) result.success(false)
        else write(call, text.toByteArray(Charsets.UTF_8), result)
      }
      "printRawText" -> {
        val raw = call.argument<String>("raw")
        val data = try {
          raw?.let { Base64.decode(it, Base64.DEFAULT) }
        } catch (e: IllegalArgumentException) {
          null
        }
        if (data == null) result.error(ERROR_CODE, "Invalid base64 data", null)
        else write(call, data, result)
      }
      "write" -> {
        val data = call.argument<ByteArray>("data")
        if (data != null) write(call, data, result) else result.success(false)
      }
      "checkDeviceConn" -> {
        result.success(usbConnCache[MethodCallParser.parseDeviceId(call)]?.isConn == true)
      }
      "connect" -> launchReply(result, "Connection failed") {
        val conn = obtainConn(call)
        withContext(Dispatchers.IO) { conn.connect() }
      }
      "disconnect" -> {
        // Idempotent: closing something that isn't open is not an error.
        usbConnCache.remove(MethodCallParser.parseDeviceId(call))?.let { conn ->
          pluginScope.launch(Dispatchers.IO) { conn.disconnect() }
        }
        result.success(true)
      }
      "checkDevicePermission" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) result.success(UsbDeviceHelper.instance.hasPermission(device.usbDevice))
        else result.error(ERROR_CODE, ERROR_USB, null)
      }
      "requestDevicePermission" -> {
        val device = MethodCallParser.parseDevice(call)
        if (device != null) launchReply(result, ERROR_PERMISSION) {
          UsbDeviceHelper.instance.requestPermissionAndWait(device.usbDevice)
        } else result.error(ERROR_CODE, ERROR_USB, null)
      }
      "queryStatus" -> {
        val query = call.argument<ByteArray>("data") ?: ByteArray(0)
        val timeout = (call.argument<Int>("timeoutMs") ?: 1000).coerceIn(1, 30000)
        pluginScope.launch {
          // Never throws to Dart: unsupported / no reply / no device -> null.
          val reply = try {
            val conn = obtainConn(call)
            withContext(Dispatchers.IO) { conn.query(query, timeout) }
          } catch (e: Exception) {
            null
          }
          result.success(reply)
        }
      }
      "removeUsbConnCache" -> {
        removeConnCacheWithKey(MethodCallParser.parseDeviceId(call))
        result.success(true)
      }
      else -> result.notImplemented()
    }
  }

  private fun <T> launchReply(result: Result, fallback: String, block: suspend () -> T) {
    pluginScope.launch {
      try {
        result.success(block())
      } catch (e: Exception) {
        result.error(ERROR_CODE, e.message ?: fallback, null)
      }
    }
  }

  /**
   * Cached connection for the call's vendorId/productId. Asks for permission
   * (and waits for the user) when the device has none yet. Throws if the device
   * is absent or permission is refused. Must run on Main.
   */
  private suspend fun obtainConn(call: MethodCall): UsbConn {
    val key = MethodCallParser.parseDeviceId(call)
    val cached = usbConnCache[key]
    if (cached != null && cached.isConn) return cached
    val device = MethodCallParser.parseDevice(call)?.usbDevice ?: throw Exception(ERROR_USB)
    if (!UsbDeviceHelper.instance.requestPermissionAndWait(device)) throw Exception(ERROR_PERMISSION)
    // Reuse the cached conn only if it still wraps the same attached device.
    if (cached != null && cached.device.deviceName == device.deviceName) return cached
    cached?.let { old -> withContext(Dispatchers.IO) { old.disconnect() } }
    val fresh = UsbConn(device)
    usbConnCache[key] = fresh
    return fresh
  }

  private fun write(call: MethodCall, bytes: ByteArray, result: Result) {
    launchReply(result, "Write failed") {
      val conn = obtainConn(call)
      withContext(Dispatchers.IO) { conn.writeBytes(bytes) }
      true
    }
  }

  private fun removeConnCacheWithKey(key: String) {
    usbConnCache.keys.filter { it == key }.forEach { k ->
      usbConnCache.remove(k)?.let { conn ->
        pluginScope.launch(Dispatchers.IO) { conn.disconnect() }
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    MessageSender.eventSink = null
    UsbDeviceHelper.instance.unRegisterUsbReceiver(binding.applicationContext)
    val conns = usbConnCache.values.toList()
    usbConnCache.clear()
    conns.forEach { try { it.disconnect() } catch (_: Exception) {} }
    pluginScope.cancel()
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    MessageSender.eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    MessageSender.eventSink = null
  }
}
