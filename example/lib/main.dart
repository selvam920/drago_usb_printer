import 'dart:convert';
import 'dart:async';
import 'package:drago_usb_printer/drago_usb_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drago USB Printer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const PrinterHomePage(),
    );
  }
}

class PrinterHomePage extends StatefulWidget {
  const PrinterHomePage({super.key});

  @override
  State<PrinterHomePage> createState() => _PrinterHomePageState();
}

class _PrinterHomePageState extends State<PrinterHomePage> {
  final DragoUsbPrinter _printer = DragoUsbPrinter();
  final TextEditingController _textController = TextEditingController(
    text: 'Hello from Drago USB Printer!',
  );

  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic>? _selectedDevice;
  bool _isConnected = false;
  bool _isLoading = false;
  bool _isPrinting = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _scanDevices();
  }

  @override
  void dispose() {
    _textController.dispose();
    if (_isConnected) _printer.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _scanDevices() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Scanning for USB printers…';
    });
    try {
      final results = await DragoUsbPrinter.getUSBDeviceList();
      setState(() {
        _devices = results;
        _statusMessage = results.isEmpty
            ? 'No USB printers found. Connect a printer and tap Scan.'
            : '${results.length} printer(s) found';
        // Clear selection if the previously-selected device is gone
        if (_selectedDevice != null &&
            !results.any((d) =>
                d['vendorId'] == _selectedDevice!['vendorId'] &&
                d['productId'] == _selectedDevice!['productId'])) {
          _selectedDevice = null;
          _isConnected = false;
        }
      });
    } catch (e) {
      _showStatus('Scan failed: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _connectToDevice(Map<String, dynamic> device) async {
    final vendorId = int.parse(device['vendorId']);
    final productId = int.parse(device['productId']);

    setState(() {
      _isLoading = true;
      _statusMessage = 'Connecting…';
    });
    try {
      final connected = await _printer.connect(vendorId, productId) ?? false;
      setState(() {
        _isConnected = connected;
        _selectedDevice = connected ? device : null;
      });
      _showStatus(
        connected ? 'Connected to ${_deviceLabel(device)}' : 'Connection failed',
        isError: !connected,
      );
    } catch (e) {
      _showStatus('Connection error: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _isLoading = true);
    try {
      await _printer.close();
      setState(() {
        _isConnected = false;
        _selectedDevice = null;
      });
      _showStatus('Disconnected');
    } catch (e) {
      _showStatus('Disconnect error: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _printText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showStatus('Enter some text first', isError: true);
      return;
    }
    await _doPrint(() => _printer.printText('$text\n'));
  }

  Future<void> _printRawBytes() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showStatus('Enter some text first', isError: true);
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode('$text\n'));
    await _doPrint(() => _printer.write(bytes));
  }

  Future<void> _printTestReceipt() async {
    // ESC/POS initialize + simple receipt
    final List<int> escPos = [
      0x1B, 0x40, // ESC @ — Initialize printer
      0x1B, 0x61, 0x01, // ESC a 1 — Center align
      0x1B, 0x45, 0x01, // ESC E 1 — Bold ON
      ...utf8.encode('DRAGO USB PRINTER\n'),
      0x1B, 0x45, 0x00, // ESC E 0 — Bold OFF
      ...utf8.encode('------------------------------\n'),
      0x1B, 0x61, 0x00, // ESC a 0 — Left align
      ...utf8.encode('Item              Qty   Price\n'),
      ...utf8.encode('Widget A            2   \$4.00\n'),
      ...utf8.encode('Widget B            1   \$7.50\n'),
      ...utf8.encode('Widget C            3   \$2.25\n'),
      ...utf8.encode('------------------------------\n'),
      0x1B, 0x61, 0x02, // ESC a 2 — Right align
      0x1B, 0x45, 0x01,
      ...utf8.encode('TOTAL: \$22.25\n'),
      0x1B, 0x45, 0x00,
      0x1B, 0x61, 0x01, // Center
      ...utf8.encode('\nThank you!\n\n\n'),
      0x1D, 0x56, 0x00, // GS V 0 — Full cut
    ];
    await _doPrint(() => _printer.write(Uint8List.fromList(escPos)));
  }

  Future<void> _doPrint(Future<bool?> Function() printFn) async {
    if (!_isConnected) {
      _showStatus('Connect to a printer first', isError: true);
      return;
    }
    setState(() => _isPrinting = true);
    try {
      final ok = await printFn() ?? false;
      _showStatus(ok ? 'Print successful' : 'Print returned false', isError: !ok);
    } catch (e) {
      _showStatus('Print error: $e', isError: true);
    } finally {
      setState(() => _isPrinting = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _deviceLabel(Map<String, dynamic> d) {
    final product = d['productName'] ?? '';
    final manufacturer = d['manufacturer'] ?? '';
    if (product.toString().isNotEmpty) return '$manufacturer $product'.trim();
    return 'Printer (${d['vendorId']}:${d['productId']})';
  }

  void _showStatus(String msg, {bool isError = false}) {
    setState(() => _statusMessage = msg);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('USB Printer Demo'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Scan for printers',
            onPressed: _isLoading ? null : _scanDevices,
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading && _devices.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                children: [
                  // ---- Status card ----
                  if (_statusMessage != null) ...[
                    Card(
                      color: cs.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              _isConnected
                                  ? Icons.check_circle_outline
                                  : Icons.info_outline,
                              color: cs.onSecondaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _statusMessage!,
                                style: TextStyle(
                                    color: cs.onSecondaryContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ---- Device list ----
                  Text('Printers',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_devices.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.usb_off,
                                size: 48, color: cs.outline),
                            const SizedBox(height: 12),
                            Text(
                              'No printers detected',
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(color: cs.outline),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              onPressed: _scanDevices,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Scan Again'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ..._devices.map((device) {
                    final isSelected = _selectedDevice != null &&
                        _selectedDevice!['vendorId'] == device['vendorId'] &&
                        _selectedDevice!['productId'] == device['productId'];
                    return Card(
                      elevation: isSelected ? 3 : 1,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: isSelected
                            ? BorderSide(color: cs.primary, width: 2)
                            : BorderSide.none,
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        leading: CircleAvatar(
                          backgroundColor:
                              isSelected ? cs.primary : cs.surfaceContainerHighest,
                          child: Icon(
                            Icons.print,
                            color: isSelected
                                ? cs.onPrimary
                                : cs.onSurfaceVariant,
                          ),
                        ),
                        title: Text(
                          _deviceLabel(device),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          'VID: ${device['vendorId']}  PID: ${device['productId']}',
                        ),
                        trailing: isSelected && _isConnected
                            ? FilledButton.tonal(
                                onPressed: _isLoading ? null : _disconnect,
                                child: const Text('Disconnect'),
                              )
                            : FilledButton(
                                onPressed: _isLoading
                                    ? null
                                    : () => _connectToDevice(device),
                                child: const Text('Connect'),
                              ),
                      ),
                    );
                  }),

                  const SizedBox(height: 24),

                  // ---- Print section ----
                  Text('Print',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _textController,
                            decoration: InputDecoration(
                              labelText: 'Text to print',
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () => _textController.clear(),
                              ),
                            ),
                            maxLines: 3,
                            minLines: 1,
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed:
                                    _isConnected && !_isPrinting ? _printText : null,
                                icon: const Icon(Icons.text_fields),
                                label: const Text('Print Text'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed:
                                    _isConnected && !_isPrinting ? _printRawBytes : null,
                                icon: const Icon(Icons.code),
                                label: const Text('Write Raw'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _isConnected && !_isPrinting
                                    ? _printTestReceipt
                                    : null,
                                icon: const Icon(Icons.receipt_long),
                                label: const Text('Test Receipt'),
                              ),
                            ],
                          ),
                          if (_isPrinting) ...[
                            const SizedBox(height: 16),
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
