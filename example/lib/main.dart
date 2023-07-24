import 'dart:convert';
import 'package:drago_usb_printer/drago_usb_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

class _MyAppState extends State<MyApp> {
  List<Map<String, dynamic>> devices = [];
  DragoUsbPrinter dragoUsbPrinter = DragoUsbPrinter();

  @override
  initState() {
    super.initState();
    _getDevicelist();
  }

  _getDevicelist() async {
    List<Map<String, dynamic>> results = [];
    results = await DragoUsbPrinter.getUSBDeviceList();

    print(" length: ${results.length}");
    setState(() {
      devices = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      home: new Scaffold(
        appBar: new AppBar(
          title: new Text('USB PRINTER'),
          actions: <Widget>[
            new IconButton(
                icon: new Icon(Icons.refresh),
                onPressed: () => _getDevicelist()),
          ],
        ),
        body: devices.length > 0
            ? new ListView(
                scrollDirection: Axis.vertical,
                children: _buildList(devices),
              )
            : null,
      ),
    );
  }

  List<Widget> _buildList(List<Map<String, dynamic>> devices) {
    return devices
        .map((device) => new ListTile(
              leading: new Icon(Icons.usb),
              title: new Text(
                  device['manufacturer'] + " " + device['productName']),
              subtitle:
                  new Text(device['vendorId'] + " " + device['productId']),
              trailing: new IconButton(
                  icon: new Icon(Icons.print),
                  onPressed: () async {
                    int vendorId = int.parse(device['vendorId']);
                    int productId = int.parse(device['productId']);
                    bool? isConnected =
                        await dragoUsbPrinter.connect(vendorId, productId);
                    if (isConnected ?? false) {
                      var data = Uint8List.fromList(utf8
                          .encode(" Hello world Testing ESC POS printer..."));
                      await dragoUsbPrinter.write(data);
                      await dragoUsbPrinter.close();
                    }
                  }),
            ))
        .toList();
  }
}
