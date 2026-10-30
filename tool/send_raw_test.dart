@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drago_usb_printer/drago_usb_printer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Manual hardware check, not a unit test: sends RAW_FILE (a file path) or
/// RAW_TEXT (`\r\n` escapes allowed) to the Windows printer RAW_PRINTER as
/// one RAW spooler job.
void main() {
  test('send raw', () {
    final env = Platform.environment;
    final printer = env['RAW_PRINTER']!;
    final file = env['RAW_FILE'] ?? '';
    final Uint8List data = file.isNotEmpty
        ? File(file).readAsBytesSync()
        : Uint8List.fromList(
            latin1.encode(env['RAW_TEXT']!.replaceAll(r'\r\n', '\r\n')));
    WindowsSpooler.writeRaw(printer, data, docName: 'raw check');
    // ignore: avoid_print
    print('sent ${data.length} bytes to $printer');
  });
}
