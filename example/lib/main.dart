import 'dart:async';
import 'dart:io';

import 'package:drago_usb_printer/drago_usb_printer.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'jobs.dart';
import 'label_tab.dart';
import 'printers_section.dart';
import 'receipt_tab.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drago USB Printer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const PrinterHomePage(),
    );
  }
}

enum UseAs { receipt, label, both }

class PrinterHomePage extends StatefulWidget {
  const PrinterHomePage({super.key});

  @override
  State<PrinterHomePage> createState() => _PrinterHomePageState();
}

class _PrinterHomePageState extends State<PrinterHomePage>
    with SingleTickerProviderStateMixin {
  final DragoUsbPrinter _printer = DragoUsbPrinter();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic>? _selected;
  bool _connected = false;
  bool _loading = false;
  bool _busy = false;
  String _result = 'Ready';
  bool _resultError = false;
  UseAs _useAs = UseAs.both;
  LabelLang _labelLang = LabelLang.tspl;

  static bool get _isWindows => !kIsWeb && Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() => _set(() {}));
    _scan();
  }

  @override
  void dispose() {
    _tabs.dispose();
    if (_connected) _printer.close();
    super.dispose();
  }

  /// setState that is a no-op once the page is gone (awaits can outlive it).
  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _report(String msg, {bool error = false}) => _set(() {
        _result = msg;
        _resultError = error;
      });

  Future<void> _scan() async {
    _set(() => _loading = true);
    try {
      final results = await DragoUsbPrinter.getUSBDeviceList();
      _set(() {
        _devices = results;
        if (_selected != null &&
            !results.any((d) => deviceKey(d) == deviceKey(_selected!))) {
          _selected = null;
          _connected = false;
        }
      });
      _report(results.isEmpty
          ? 'No printers found'
          : '${results.length} printer(s) found');
    } catch (e) {
      _report('Scan failed: $e', error: true);
    } finally {
      _set(() => _loading = false);
    }
  }

  Future<void> _connect(Map<String, dynamic> device) async {
    _set(() => _loading = true);
    try {
      final name = device['printerName'] as String?;
      final bool ok;
      if (name != null) {
        // Windows: an installed printer, opened by name (RAW spooler jobs).
        ok = await _printer.connectPrinter(name);
      } else {
        final vid = int.tryParse('${device['vendorId']}');
        final pid = int.tryParse('${device['productId']}');
        if (vid == null || pid == null) {
          _report('Invalid device ids', error: true);
          return;
        }
        ok = await _printer.connect(vid, pid) ?? false;
      }
      _set(() {
        _connected = ok;
        _selected = ok ? device : null;
        if (ok) _labelLang = _defaultLang(device);
      });
      _report(
          ok
              ? 'Connected to ${deviceLabel(device)}'
              : 'Could not connect to ${deviceLabel(device)}',
          error: !ok);
    } catch (e) {
      _report('Connection error: $e', error: true);
    } finally {
      _set(() => _loading = false);
    }
  }

  /// LD0801 / DeTong DP27 speak ESC/POS raster only (no TSPL).
  LabelLang _defaultLang(Map<String, dynamic> d) {
    final name = '${d['printerName'] ?? ''}'.toUpperCase();
    return _isWindows && (name.contains('LD0801') || name.contains('DP27'))
        ? LabelLang.escpos
        : LabelLang.tspl;
  }

  Future<void> _disconnect() async {
    _set(() => _loading = true);
    try {
      await _printer.close();
      _set(() {
        _connected = false;
        _selected = null;
      });
      _report('Disconnected');
    } catch (e) {
      _report('Disconnect error: $e', error: true);
    } finally {
      _set(() => _loading = false);
    }
  }

  Future<void> _run(String name, Uint8List Function() build) async {
    if (!_connected) {
      _report('Connect to a printer first', error: true);
      return;
    }
    _set(() {
      _busy = true;
      _result = 'Printing $name...';
      _resultError = false;
    });
    try {
      final bytes = build();
      final ok = await _printer.write(bytes) ?? false;
      _report(ok ? '$name sent (${bytes.length} bytes)' : '$name: write failed',
          error: !ok);
    } catch (e) {
      _report('$name: ${e is FormatException ? e.message : e}', error: true);
    } finally {
      _set(() => _busy = false);
    }
  }

  /// Which language the status query uses: the label language on the label
  /// tab, ESC/POS otherwise.
  LabelLang get _statusLang {
    final onLabel =
        _useAs == UseAs.label || (_useAs == UseAs.both && _tabs.index == 1);
    return onLabel ? _labelLang : LabelLang.escpos;
  }

  Future<void> _status() async {
    if (!_connected) {
      _report('Connect to a printer first', error: true);
      return;
    }
    final lang = _statusLang;
    _set(() => _busy = true);
    try {
      final reply = await _printer.queryStatus(statusQuery(lang),
          timeout: const Duration(milliseconds: 1500));
      if (reply == null || reply.isEmpty) {
        _report(_isWindows
            ? 'Status: no reply (not supported on Windows)'
            : 'Status: no reply');
      } else {
        _report('Status: ${describeStatus(lang, reply)}');
      }
    } catch (e) {
      _report('Status error: $e', error: true);
    } finally {
      _set(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Widget _printers() => PrintersSection(
        devices: _devices,
        selected: _selected,
        connected: _connected,
        loading: _loading,
        onRefresh: _scan,
        onConnect: _connect,
        onDisconnect: _disconnect,
      );

  Widget _useAsPicker() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const Text('Use as'),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<UseAs>(
              segments: const [
                ButtonSegment(
                    value: UseAs.receipt,
                    icon: Icon(Icons.receipt_long),
                    label: Text('Receipt')),
                ButtonSegment(
                    value: UseAs.label,
                    icon: Icon(Icons.label_outline),
                    label: Text('Label')),
                ButtonSegment(value: UseAs.both, label: Text('Both')),
              ],
              selected: {_useAs},
              onSelectionChanged: (s) => setState(() => _useAs = s.first),
            ),
          ),
        ]),
      );

  Widget _jobs() {
    final on = _connected && !_busy;
    final receipt = ReceiptTab(enabled: on, run: _run);
    final label = LabelTab(
      enabled: on,
      run: _run,
      lang: _labelLang,
      onLang: (l) => setState(() => _labelLang = l),
    );
    final Widget body = switch (_useAs) {
      UseAs.receipt => receipt,
      UseAs.label => label,
      UseAs.both => Column(children: [
          TabBar(controller: _tabs, tabs: const [
            Tab(icon: Icon(Icons.receipt_long), text: 'Receipt'),
            Tab(icon: Icon(Icons.label_outline), text: 'Label'),
          ]),
          Expanded(
            child: TabBarView(controller: _tabs, children: [receipt, label]),
          ),
        ]),
    };
    return Column(children: [_useAsPicker(), Expanded(child: body)]);
  }

  Widget _resultBar() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: _resultError ? cs.errorContainer : cs.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              Icon(
                _resultError ? Icons.error_outline : Icons.info_outline,
                color: _resultError ? cs.onErrorContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _result,
                  style: TextStyle(
                      color: _resultError
                          ? cs.onErrorContainer
                          : cs.onSurfaceVariant),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected && _selected != null
            ? deviceLabel(_selected!)
            : 'USB Printer Demo'),
        actions: [
          TextButton.icon(
            onPressed: _connected && !_busy ? _status : null,
            icon: const Icon(Icons.monitor_heart_outlined),
            label: Text(
                'Status (${_statusLang == LabelLang.tspl ? 'TSPL' : 'ESC/POS'})'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _resultBar(),
      body: SafeArea(
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 380,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: _printers(),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _jobs()),
              ])
            : NestedScrollView(
                headerSliverBuilder: (context, _) => [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _printers(),
                    ),
                  ),
                ],
                body: _jobs(),
              ),
      ),
    );
  }
}
