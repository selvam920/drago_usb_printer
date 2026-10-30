import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'jobs.dart';

/// Runs one print job: [build] may throw (bad data) and is reported.
typedef PrintRun = Future<void> Function(
    String name, Uint8List Function() build);

class CodeFields extends StatelessWidget {
  const CodeFields({
    super.key,
    required this.controller,
    required this.type,
    required this.onType,
  });

  final TextEditingController controller;
  final CodeType type;
  final ValueChanged<CodeType> onType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Barcode / QR data',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final t in CodeType.values)
            ChoiceChip(
              label: Text(t.label),
              selected: type == t,
              onSelected: (_) => onType(t),
            ),
        ]),
      ],
    );
  }
}

class ReceiptTab extends StatefulWidget {
  const ReceiptTab({super.key, required this.enabled, required this.run});

  final bool enabled;
  final PrintRun run;

  @override
  State<ReceiptTab> createState() => _ReceiptTabState();
}

class _ReceiptTabState extends State<ReceiptTab> {
  Paper _paper = Paper.mm58;
  CodeType _code = CodeType.qr;
  bool _asImage = false;
  final _text = TextEditingController(text: 'Hello from Drago USB Printer!');
  final _data = TextEditingController(text: 'https://example.com');

  @override
  void dispose() {
    _text.dispose();
    _data.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Paper', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<Paper>(
          segments: [
            for (final p in Paper.values)
              ButtonSegment(
                  value: p, label: Text('${p.label} (${p.dots} dots)')),
          ],
          selected: {_paper},
          onSelectionChanged: (s) => setState(() => _paper = s.first),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: on
                ? () => widget.run('Test page', () => escposTestPage(_paper))
                : null,
            icon: const Icon(Icons.straighten),
            label: const Text('Test page'),
          ),
          FilledButton.tonalIcon(
            onPressed: on
                ? () =>
                    widget.run('Test receipt', () => escposTestReceipt(_paper))
                : null,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Test receipt'),
          ),
        ]),
        const Divider(height: 32),
        TextField(
          controller: _text,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Text to print',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: on
                ? () => widget.run('Text', () {
                      final t = _text.text.trim();
                      if (t.isEmpty) {
                        throw const FormatException('Enter some text first');
                      }
                      return escposText(t);
                    })
                : null,
            icon: const Icon(Icons.text_fields),
            label: const Text('Print text'),
          ),
        ),
        const Divider(height: 32),
        CodeFields(
          controller: _data,
          type: _code,
          onType: (t) => setState(() => _code = t),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print as image'),
          subtitle: const Text('GS v 0 raster instead of native GS k / GS ( k'),
          value: _asImage,
          onChanged: (v) => setState(() => _asImage = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: on
                ? () => widget.run(
                    _code.label,
                    () => escposCodeReceipt(_code, _data.text.trim(), _paper,
                        asImage: _asImage))
                : null,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Print barcode / QR'),
          ),
        ),
      ],
    );
  }
}
