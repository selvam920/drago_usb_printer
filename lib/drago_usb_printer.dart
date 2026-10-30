import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'src/windows_spooler.dart';

export 'src/windows_spooler.dart' show WindowsPrinterInfo, WindowsSpooler;

class DragoUsbPrinter {
  static const MethodChannel _channel =
      const MethodChannel('drago_usb_printer');

  int vendorId = 0;
  int productId = 0;

  /// Windows: the installed printer (spooler queue) jobs go to. Set by
  /// [connectPrinter].
  String? printerName;

  static bool get _isWindows => !kIsWeb && Platform.isWindows;

  /// [getUSBDeviceList]
  /// Android: attached USB printers. Windows: installed printers (default
  /// first) -- each map carries `printerName`, `port` (USB001,
  /// IP_..., ...), `isDefault` and `isOffline`; pass `printerName` to
  /// [connectPrinter].
  static Future<List<Map<String, dynamic>>> getUSBDeviceList() async {
    if (_isWindows) {
      try {
        return [for (final p in WindowsSpooler.listPrinters()) p.toMap()];
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }
    if (Platform.isAndroid) {
      final List<dynamic> devices =
          await _channel.invokeMethod<List<dynamic>>('getUSBDeviceList') ??
              const [];
      var result = devices
          .cast<Map<dynamic, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      return result;
    } else {
      return <Map<String, dynamic>>[];
    }
  }

  /// [connect]
  /// connect to a printer vai vendorId and productId
  Future<bool?> connect(int vendorId, int productId) async {
    this.vendorId = vendorId;
    this.productId = productId;
    if (_isWindows) {
      // Windows printers have no USB ids; they are opened by name.
      final name = printerName;
      return name != null && WindowsSpooler.exists(name);
    }

    Map<String, dynamic> params = {
      "vendorId": vendorId,
      "productId": productId
    };
    final bool? result = await _channel.invokeMethod('connect', params);
    debugPrint('drago_usb_printer connected $result');
    return result;
  }

  /// Windows: selects the installed printer [name] (from
  /// [getUSBDeviceList]'s `printerName`). Returns false when no such
  /// queue exists, and on other platforms.
  Future<bool> connectPrinter(String name) async {
    if (!_isWindows) return false;
    printerName = name;
    return WindowsSpooler.exists(name);
  }

  /// Windows: one RAW spooler job to [printerName].
  Future<bool> _windowsWrite(Uint8List data) async {
    final name = printerName;
    if (name == null) throw Exception('No printer selected (connectPrinter)');
    WindowsSpooler.writeRaw(name, data);
    return true;
  }

  /// [close]
  /// close the connection after print with usb printer
  Future<bool?> close() async {
    if (_isWindows) return true; // each Windows job opens/closes itself
    Map<String, dynamic> params = {
      "vendorId": vid ?? vendorId,
      "productId": pid ?? productId
    };
    final bool? result = await _channel.invokeMethod('disconnect', params);
    return result;
  }

  /// [printText]
  /// print text
  Future<bool?> printText(String text) async {
    if (_isWindows) {
      return _windowsWrite(Uint8List.fromList(utf8.encode(text)));
    }
    Map<String, dynamic> params = {
      "text": text,
      "vendorId": vid ?? vendorId,
      "productId": pid ?? productId
    };
    final bool? result = await _channel.invokeMethod('printText', params);
    return result;
  }

  /// [printRawText]
  /// print raw text
  Future<bool?> printRawText(String text) async {
    if (_isWindows) return _windowsWrite(base64.decode(text));
    Map<String, dynamic> params = {
      "raw": text,
      "vendorId": vid ?? vendorId,
      "productId": pid ?? productId
    };
    final bool? result = await _channel.invokeMethod('printRawText', params);
    return result;
  }

  /// [write]
  /// write data byte
  Future<bool?> write(Uint8List data) async {
    if (_isWindows) return _windowsWrite(data);
    Map<String, dynamic> params = {
      "data": data,
      "vendorId": vid ?? vendorId,
      "productId": pid ?? productId
    };
    final bool? result = await _channel.invokeMethod('write', params);
    return result;
  }

  /// [queryStatus]
  /// Writes [query] (e.g. ESC/POS `DLE EOT n` or TSPL `ESC ! ?`) to the
  /// connected printer and returns the first reply packet, or `null` when the
  /// printer has no IN endpoint, does not answer within [timeout], is not
  /// connected, or the platform is unsupported. Never throws.
  Future<Uint8List?> queryStatus(Uint8List query,
      {Duration timeout = const Duration(seconds: 1)}) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('queryStatus', {
        "data": query,
        "timeoutMs": timeout.inMilliseconds,
        "vendorId": vendorId,
        "productId": productId,
      });
    } catch (_) {
      return null;
    }
  }
}
