@TestOn('windows')
library;

import 'package:drago_usb_printer/drago_usb_printer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lists installed Windows printers without crashing', () async {
    final list = await DragoUsbPrinter.getUSBDeviceList();
    for (final p in list) {
      // ignore: avoid_print
      print('${p['printerName']} | port ${p['port']} | '
          'default ${p['isDefault']} | offline ${p['isOffline']}');
      expect(p['printerName'], isNotEmpty);
    }
    expect(list.where((p) => p['isDefault'] == true).length, lessThanOrEqualTo(1));
    if (list.isNotEmpty) {
      final printer = DragoUsbPrinter();
      expect(await printer.connectPrinter(list.first['printerName']), isTrue);
    }
    expect(await DragoUsbPrinter().connectPrinter('no such printer xyz'), isFalse);
  });
}
