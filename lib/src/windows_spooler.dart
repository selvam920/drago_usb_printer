import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// An installed Windows printer (spooler queue).
class WindowsPrinterInfo {
  const WindowsPrinterInfo({
    required this.name,
    required this.driver,
    required this.port,
    required this.isDefault,
    required this.isOffline,
  });

  final String name;
  final String driver;

  /// "USB001", "IP_192.168.1.50", "COM3", "PORTPROMPT:" ...
  final String port;
  final bool isDefault;
  final bool isOffline;

  bool get isUsb => port.toUpperCase().startsWith('USB');

  /// Same keys as the Android device map, plus Windows-only ones, so callers
  /// can treat both lists alike. Windows printers have no USB ids -- they are
  /// addressed by [name].
  Map<String, dynamic> toMap() => {
        'deviceName': name,
        'productName': name,
        'manufacturer': driver,
        'deviceId': '0',
        'vendorId': '0',
        'productId': '0',
        'printerName': name,
        'port': port,
        'isDefault': isDefault,
        'isOffline': isOffline,
      };
}

/// Installed printers and RAW jobs through the Windows print spooler. RAW
/// means the bytes (ESC/POS, TSPL, ZPL...) go to the printer untouched --
/// the driver does no rendering.
class WindowsSpooler {
  WindowsSpooler._();

  // winspool.h values not exported by package:win32.
  static const _statusOffline = 0x00000080; // PRINTER_STATUS_OFFLINE
  static const _attrWorkOffline = 0x00000400; // PRINTER_ATTRIBUTE_WORK_OFFLINE

  static String _s(PWSTR p) => p.address == 0 ? '' : p.toDartString();

  static String? defaultPrinterName() {
    final size = calloc<Uint32>();
    try {
      GetDefaultPrinter(null, size); // asks for the buffer size
      if (size.value == 0) return null;
      final buf = calloc<WCHAR>(size.value);
      try {
        if (!GetDefaultPrinter(PWSTR(buf.cast()), size)) return null;
        return PWSTR(buf.cast()).toDartString();
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(size);
    }
  }

  /// Local and network-connected printers, default printer first.
  static List<WindowsPrinterInfo> listPrinters() {
    const flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    final needed = calloc<Uint32>();
    final returned = calloc<Uint32>();
    try {
      EnumPrinters(flags, null, 2, null, 0, needed, returned);
      if (needed.value == 0) return const [];
      final buf = calloc<Uint8>(needed.value);
      try {
        final ok = EnumPrinters(
            flags, null, 2, buf, needed.value, needed, returned);
        if (!ok.value) return const [];
        final def = defaultPrinterName();
        final infos = buf.cast<PRINTER_INFO_2>();
        final list = <WindowsPrinterInfo>[
          for (var i = 0; i < returned.value; i++)
            () {
              final p = (infos + i).ref;
              final name = _s(p.pPrinterName);
              return WindowsPrinterInfo(
                name: name,
                driver: _s(p.pDriverName),
                port: _s(p.pPortName),
                isDefault: name == def,
                isOffline: (p.Status & _statusOffline) != 0 ||
                    (p.Attributes & _attrWorkOffline) != 0,
              );
            }(),
        ];
        list.sort((a, b) => a.isDefault == b.isDefault
            ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
            : (a.isDefault ? -1 : 1));
        return list;
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(needed);
      calloc.free(returned);
    }
  }

  /// True when a queue called [name] can be opened.
  static bool exists(String name) {
    final h = _open(name);
    if (h == null) return false;
    ClosePrinter(h);
    return true;
  }

  static PRINTER_HANDLE? _open(String name) {
    final pName = name.toNativeUtf16();
    final ph = calloc<Pointer>();
    try {
      final ok = OpenPrinter(PCWSTR(pName), ph, nullptr);
      if (!ok.value || ph.value == nullptr) return null;
      return PRINTER_HANDLE(ph.value);
    } finally {
      calloc.free(ph);
      calloc.free(pName);
    }
  }

  /// Sends [data] to the queue [name] as one RAW job. Throws with the step
  /// that failed; always releases the handle and native memory.
  static void writeRaw(
    String name,
    Uint8List data, {
    String docName = 'drago_usb_printer',
  }) {
    final h = _open(name);
    if (h == null) throw Exception('Printer "$name" not found');
    final pDoc = docName.toNativeUtf16();
    final pType = 'RAW'.toNativeUtf16();
    final written = calloc<Uint32>();
    final info = calloc<DOC_INFO_1>()
      ..ref.pDocName = PWSTR(pDoc)
      ..ref.pOutputFile = PWSTR(nullptr)
      ..ref.pDatatype = PWSTR(pType);
    var doc = false, page = false;
    try {
      if (StartDocPrinter(h, 1, info) == 0) {
        throw Exception('StartDocPrinter failed for "$name"');
      }
      doc = true;
      if (!StartPagePrinter(h)) throw Exception('StartPagePrinter failed');
      page = true;
      // Chunked: one huge WritePrinter makes some drivers paginate / stall.
      const chunk = 4096;
      final native = calloc<Uint8>(chunk);
      try {
        for (var off = 0; off < data.length; off += chunk) {
          final n = (data.length - off) < chunk ? data.length - off : chunk;
          native.asTypedList(n).setRange(0, n, data, off);
          if (!WritePrinter(h, native, n, written) || written.value != n) {
            throw Exception('WritePrinter failed at byte $off');
          }
        }
      } finally {
        calloc.free(native);
      }
    } finally {
      if (page) EndPagePrinter(h);
      if (doc) EndDocPrinter(h);
      ClosePrinter(h);
      calloc.free(info);
      calloc.free(written);
      calloc.free(pDoc);
      calloc.free(pType);
    }
  }
}
