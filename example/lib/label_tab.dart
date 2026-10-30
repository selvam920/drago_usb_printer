import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'jobs.dart';
import 'receipt_tab.dart';

const _presets = [
  (25.0, 15.0),
  (38.0, 25.0),
  (40.0, 30.0),
  (50.0, 25.0),
  (50.0, 30.0),
  (75.0, 50.0),
  (100.0, 50.0),
];

class LabelTab extends StatefulWidget {
  const LabelTab({
    super.key,
    required this.enabled,
    required this.run,
    required this.lang,
    required this.onLang,
  });

  final bool enabled;
  final PrintRun run;
  final LabelLang lang;
  final ValueChanged<LabelLang> onLang;

  @override
  State<LabelTab> createState() => _LabelTabState();
}

class _LabelTabState extends State<LabelTab> {
  final _w = TextEditingController(text: '50');
  final _h = TextEditingController(text: '30');
  final _gap = TextEditingController(text: '2');
  final _title = TextEditingController(text: 'DRAGO LABEL');
  final _data = TextEditingController(text: '12345678');
  CodeType _code = CodeType.code128;

  @override
  void dispose() {
    for (final c in [_w, _h, _gap, _title, _data]) {
      c.dispose();
    }
    super.dispose();
  }

  LabelSize _size() {
    final w = double.tryParse(_w.text);
    final h = double.tryParse(_h.text);
    final g = double.tryParse(_gap.text) ?? 2;
    if (w == null || h == null || w < 10 || h < 10 || w > 120 || h > 300) {
      throw const FormatException('Label size must be 10-120 x 10-300 mm');
    }
    return LabelSize(w, h, g);
  }

  void _preset(double w, double h) => setState(() {
        _w.text = '${w.toInt()}';
        _h.text = '${h.toInt()}';
      });

  Widget _num(TextEditingController c, String label) => SizedBox(
        width: 96,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: label,
            suffixText: 'mm',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    final tspl = widget.lang == LabelLang.tspl;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Language', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<LabelLang>(
          segments: const [
            ButtonSegment(value: LabelLang.tspl, label: Text('TSPL')),
            ButtonSegment(
                value: LabelLang.escpos, label: Text('ESC/POS (image)')),
          ],
          selected: {widget.lang},
          onSelectionChanged: (s) => widget.onLang(s.first),
        ),
        const SizedBox(height: 16),
        Text('Size (203 dpi, 8 dots/mm)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (w, h) in _presets)
            ChoiceChip(
              label: Text('${w.toInt()}x${h.toInt()}'),
              selected: _w.text == '${w.toInt()}' && _h.text == '${h.toInt()}',
              onSelected: (_) => _preset(w, h),
            ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _num(_w, 'Width'),
          _num(_h, 'Height'),
          _num(_gap, 'Gap'),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          decoration: const InputDecoration(
            labelText: 'Label title',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        CodeFields(
          controller: _data,
          type: _code,
          onType: (t) => setState(() => _code = t),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: on
                ? () => widget.run('Sample label', () {
                      final s = _size();
                      final d = _data.text.trim();
                      return tspl
                          ? tsplSample(s, _title.text, _code, d)
                          : escposSample(s, _title.text, _code, d);
                    })
                : null,
            icon: const Icon(Icons.label_outline),
            label: const Text('Sample label'),
          ),
          FilledButton.tonalIcon(
            onPressed: on
                ? () => widget.run('${_code.label} label', () {
                      final s = _size();
                      final d = _data.text.trim();
                      return tspl
                          ? tsplCodeLabel(s, _code, d)
                          : escposCodeLabel(s, _code, d);
                    })
                : null,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Barcode / QR label'),
          ),
          if (tspl) ...[
            OutlinedButton.icon(
              onPressed:
                  on ? () => widget.run('Calibrate', tsplCalibrate) : null,
              icon: const Icon(Icons.tune),
              label: const Text('Calibrate'),
            ),
            OutlinedButton.icon(
              onPressed:
                  on ? () => widget.run('Self test', tsplSelfTest) : null,
              icon: const Icon(Icons.build_outlined),
              label: const Text('Self test'),
            ),
          ],
        ]),
        if (!tspl) ...[
          const SizedBox(height: 12),
          Text(
            'ESC/POS labels are sent as one GS v 0 image and end with '
            'GS FF (1D 0C) to feed to the next label.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
