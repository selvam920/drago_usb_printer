# drago_usb_printer

This plugin will allow develop send data and work with usb printer on android

## Getting Started

```
    flutter pub add drago_usb_printer
```

## Example of Usage

```
_getDevicelist() async {
    List<Map<String, dynamic>> results = [];
    results = await DragoUsbPrinter.getUSBDeviceList();

    print(" length: ${results.length}");
    setState(() {
      devices = results;
    });
}

_connect(int vendorId, int productId) async {
    bool returned;
    try {
      returned = await DragoUsbPrinter.connect(vendorId, productId);
    } on PlatformException {
      //response = 'Failed to get platform version.';
    }
    if (returned) {
      setState(() {
        connected = true;
      });
    }
}

_print() async {
    try {
      var data = Uint8List.fromList(
          utf8.encode(" Hello world Testing ESC POS printer..."));
      await DragoUsbPrinter.write(data);
      // await DragoUsbPrinter.printRawData("text");
      // await DragoUsbPrinter.printText("Testing ESC POS printer...");
    } on PlatformException {
      //response = 'Failed to get platform version.';
    }
}

```
