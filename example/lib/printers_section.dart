import 'package:material_ui/material_ui.dart';

/// Windows printers share vendor/product id 0 -- tell them apart by name.
String deviceKey(Map<String, dynamic> d) =>
    '${d['printerName'] ?? ''}|${d['vendorId']}|${d['productId']}';

String deviceLabel(Map<String, dynamic> d) {
  if (d['printerName'] != null) return '${d['printerName']}';
  final product = '${d['productName'] ?? ''}';
  final manufacturer = '${d['manufacturer'] ?? ''}';
  if (product.isNotEmpty) return '$manufacturer $product'.trim();
  return 'Printer (${d['vendorId']}:${d['productId']})';
}

class PrintersSection extends StatelessWidget {
  const PrintersSection({
    super.key,
    required this.devices,
    required this.selected,
    required this.connected,
    required this.loading,
    required this.onRefresh,
    required this.onConnect,
    required this.onDisconnect,
  });

  final List<Map<String, dynamic>> devices;
  final Map<String, dynamic>? selected;
  final bool connected;
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, dynamic>> onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.print_outlined, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('Printers', style: theme.textTheme.titleMedium)),
              if (connected)
                TextButton.icon(
                  onPressed: loading ? null : onDisconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            if (loading) const LinearProgressIndicator(),
            if (devices.isEmpty && !loading)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Icon(Icons.usb_off, size: 40, color: cs.outline),
                  const SizedBox(height: 8),
                  Text('No printers found',
                      style: TextStyle(color: cs.outline)),
                ]),
              ),
            for (final d in devices) _tile(context, d),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> d) {
    final cs = Theme.of(context).colorScheme;
    final isSel = selected != null && deviceKey(selected!) == deviceKey(d);
    final isWin = d['printerName'] != null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ListTile(
        selected: isSel,
        selectedTileColor: cs.primaryContainer,
        selectedColor: cs.onPrimaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: isSel ? cs.primary : cs.outlineVariant,
              width: isSel ? 2 : 1),
        ),
        leading: Icon(isSel && connected ? Icons.check_circle : Icons.print),
        title:
            Text(deviceLabel(d), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(isWin
                ? 'Port ${d['port'] ?? '-'}'
                : 'VID ${d['vendorId']}  PID ${d['productId']}'),
            if (d['isDefault'] == true) _tag(context, 'Default', cs.primary),
            if (d['isOffline'] == true) _tag(context, 'Offline', cs.error),
          ],
        ),
        onTap: loading ? null : () => onConnect(d),
        trailing: isSel && connected
            ? const Text('Connected')
            : const Icon(Icons.chevron_right),
      ),
    );
  }

  Widget _tag(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 11)),
      );
}
