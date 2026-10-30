## 0.0.1

* first release

## 0.0.3

* Upgraded to Android gradle 7.2.2

## 0.0.4

* Fix kotlin version

## 0.0.5

* Flutter 3.10

## 0.0.6

* Write bytes by vendorid and productid

## 0.0.7

* Fix disconnect

## 0.0.8

* Fix disconnect

## 0.0.9

* Migrated to flutter >= 3.3.0

## 0.1.0

* Migrated to gradle > 8.0

## 0.1.1

* Fixed issue with <= android 11

## 0.1.2

* Fixed issue with >= android 14

## 0.1.3

* Improve usb print performance 

## 0.1.4

* Improve bulk usb print

## 0.1.5

* Upgrade Android AGP 

## 0.1.6

* Fix Android AGP 
## 0.1.7
* Printers without a bulk IN endpoint (most label printers) now connect.
* Vendor-class (0xFF) printers are listed and connectable; non-printers (storage, HID, hub, audio, video) skipped.
* Fix crash when the device can't be opened; connections no longer leak on claim failure or reconnect.
* Ask for USB permission and wait for the answer on connect/write/print instead of reporting "not found".
* Connect and write run off the main thread; thread-safe connection cache; exact-match cleanup on detach.
* A zero-byte transfer no longer loops forever; a failed write drops the connection so the next print reconnects.
* Every method replies exactly once (`printText` null, bad base64, unknown methods); `disconnect` when not connected returns true.
* Receiver registered once and unregistered safely.
* Windows: `getUSBDeviceList` lists installed printers (default first, with `printerName`, `port`, `isDefault`, `isOffline`); `connectPrinter(name)` selects one and `write` / `printText` / `printRawText` send RAW spooler jobs. Pure Dart (win32), no native code.
* New: `queryStatus(query, {timeout})` returns the printer's status reply (null when unsupported).