// Byte builders for the example's print jobs. Pure Dart: no widgets, no I/O.
import 'dart:convert';
import 'dart:typed_data';

import 'package:barcode/barcode.dart';
import 'package:image/image.dart' as img;

enum CodeType { qr, code128, ean13 }

extension CodeTypeX on CodeType {
  String get label => switch (this) {
        CodeType.qr => 'QR',
        CodeType.code128 => 'Code128',
        CodeType.ean13 => 'EAN-13',
      };

  Barcode get barcode => switch (this) {
        CodeType.qr => Barcode.qrCode(),
        CodeType.code128 => Barcode.code128(),
        CodeType.ean13 => Barcode.ean13(),
      };

  bool get is2d => this == CodeType.qr;
}

/// Throws a readable error when [data] cannot be encoded as [type].
void checkCode(CodeType type, String data) {
  if (data.isEmpty) throw const FormatException('Enter barcode data first');
  final bc = type.barcode;
  if (!bc.isValid(data)) {
    throw FormatException(type == CodeType.ean13
        ? 'EAN-13 needs 12 or 13 digits (valid check digit)'
        : 'Data is not valid for ${type.label}');
  }
}

// ---------------------------------------------------------------------------
// ESC/POS
// ---------------------------------------------------------------------------

const _init = [0x1B, 0x40];
const _cut = [0x1D, 0x56, 0x00]; // GS V 0
const _formFeed = [0x1D, 0x0C]; // GS FF: next label
List<int> _align(int n) => [0x1B, 0x61, n];
List<int> _bold(bool on) => [0x1B, 0x45, on ? 1 : 0];
List<int> _size(int w, int h) => [0x1D, 0x21, ((w - 1) << 4) | (h - 1)];
List<int> _t(String s) => utf8.encode(s);

/// Receipt paper: 58mm = 384 dots / 32 chars, 80mm = 576 dots / 48 chars.
enum Paper { mm58, mm80 }

extension PaperX on Paper {
  int get dots => this == Paper.mm58 ? 384 : 576;
  int get chars => this == Paper.mm58 ? 32 : 48;
  String get label => this == Paper.mm58 ? '58 mm' : '80 mm';
}

Uint8List escposTestPage(Paper p) {
  final ruler = StringBuffer();
  for (var i = 1; i <= p.chars; i++) {
    ruler.write(i % 10);
  }
  return Uint8List.fromList([
    ..._init,
    ..._align(1),
    ..._bold(true),
    ..._t('TEST PAGE ${p.label}\n'),
    ..._bold(false),
    ..._align(0),
    ..._t('$ruler\n'),
    ..._t('${'-' * p.chars}\n'),
    ..._t('Left aligned\n'),
    ..._align(1),
    ..._t('Centered\n'),
    ..._align(2),
    ..._t('Right aligned\n'),
    ..._align(0),
    ..._bold(true),
    ..._t('Bold text\n'),
    ..._bold(false),
    ..._size(2, 2),
    ..._t('Double 2x\n'),
    ..._size(1, 1),
    ..._t('${p.dots} dots / ${p.chars} chars\n\n\n\n'),
    ..._cut,
  ]);
}

Uint8List escposText(String text) =>
    Uint8List.fromList([..._init, ..._t('$text\n\n\n\n'), ..._cut]);

String _row(String left, String right, int width) {
  final space = width - left.length - right.length;
  return space < 1 ? '$left $right' : '$left${' ' * space}$right';
}

Uint8List escposTestReceipt(Paper p) {
  final w = p.chars;
  return Uint8List.fromList([
    ..._init,
    ..._align(1),
    ..._bold(true),
    ..._size(2, 2),
    ..._t('DRAGO STORE\n'),
    ..._size(1, 1),
    ..._bold(false),
    ..._t('12 Example Street\n'),
    ..._t('${'-' * w}\n'),
    ..._align(0),
    ..._t('${_row('Item  x Qty', 'Amount', w)}\n'),
    ..._t('${_row('Widget A  x 2', '8.00', w)}\n'),
    ..._t('${_row('Widget B  x 1', '7.50', w)}\n'),
    ..._t('${_row('Widget C  x 3', '6.75', w)}\n'),
    ..._t('${'-' * w}\n'),
    ..._bold(true),
    ..._t('${_row('TOTAL', '22.25', w)}\n'),
    ..._bold(false),
    ..._align(1),
    ..._t('\nThank you!\n\n\n\n'),
    ..._cut,
  ]);
}

/// Native ESC/POS barcode (GS k) or QR (GS ( k) command.
List<int> escposNativeCode(CodeType type, String data) {
  final d = _t(data);
  switch (type) {
    case CodeType.qr:
      final n = d.length + 3;
      return [
        0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0x00, // model 2
        0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, 0x06, // module size 6
        0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, 0x31, // EC level M
        0x1D, 0x28, 0x6B, n & 0xFF, n >> 8, 0x31, 0x50, 0x30, ...d, // store
        0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30, // print
      ];
    case CodeType.code128:
      final body = [0x7B, 0x42, ...d]; // {B code set B
      return [
        0x1D, 0x68, 80, // height
        0x1D, 0x77, 2, // module width
        0x1D, 0x48, 2, // HRI below
        0x1D, 0x6B, 73, body.length, ...body,
      ];
    case CodeType.ean13:
      final digits = _t(data.substring(0, 12));
      return [
        0x1D,
        0x68,
        80,
        0x1D,
        0x77,
        2,
        0x1D,
        0x48,
        2,
        0x1D,
        0x6B,
        67,
        digits.length,
        ...digits,
      ];
  }
}

Uint8List escposCodeReceipt(CodeType type, String data, Paper p,
    {required bool asImage}) {
  checkCode(type, data);
  final List<int> code;
  if (asImage) {
    final w = type.is2d ? 240 : (p.dots - 32);
    final h = type.is2d ? 240 : 120;
    code = escposRaster(codeImage(type, data, w, h, text: true));
  } else {
    code = escposNativeCode(type, data);
  }
  return Uint8List.fromList([
    ..._init,
    ..._align(1),
    ..._t('${type.label}${asImage ? ' (image)' : ''}\n'),
    ...code,
    ..._t('\n$data\n\n\n\n'),
    ..._cut,
  ]);
}

/// GS v 0 raster of [image]: 1-bit rows, MSB first, 1 = black.
List<int> escposRaster(img.Image image) {
  final w = image.width, h = image.height;
  final bytesPerRow = (w + 7) >> 3;
  final out = <int>[
    0x1D,
    0x76,
    0x30,
    0x00,
    bytesPerRow & 0xFF,
    bytesPerRow >> 8,
    h & 0xFF,
    h >> 8,
  ];
  for (var y = 0; y < h; y++) {
    for (var bx = 0; bx < bytesPerRow; bx++) {
      var byte = 0;
      for (var bit = 0; bit < 8; bit++) {
        final x = bx * 8 + bit;
        if (x < w && image.getPixel(x, y).luminance < 128) {
          byte |= 0x80 >> bit;
        }
      }
      out.add(byte);
    }
  }
  return out;
}

final _white = img.ColorRgb8(255, 255, 255);
final _black = img.ColorRgb8(0, 0, 0);

img.Image _blank(int w, int h) =>
    img.fill(img.Image(width: w, height: h), color: _white);

/// Draws [data] as [type] into a fresh white [w]x[h] image.
img.Image codeImage(CodeType type, String data, int w, int h,
    {bool text = false}) {
  final out = _blank(w, h);
  drawCode(out, type, data, 0, 0, w, h, text: text);
  return out;
}

void drawCode(
    img.Image dst, CodeType type, String data, int x, int y, int w, int h,
    {bool text = false}) {
  final elements = type.barcode
      .make(data, width: w.toDouble(), height: h.toDouble(), drawText: false);
  for (final e in elements) {
    if (e is BarcodeBar && e.black) {
      img.fillRect(dst,
          x1: x + e.left.round(),
          y1: y + e.top.round(),
          x2: x + (e.left + e.width).round() - 1,
          y2: y + (e.top + e.height).round() - 1,
          color: _black);
    }
  }
}

// ---------------------------------------------------------------------------
// Labels (203 dpi = 8 dots/mm)
// ---------------------------------------------------------------------------

enum LabelLang { tspl, escpos }

class LabelSize {
  final double width, height, gap;
  const LabelSize(this.width, this.height, this.gap);
  int get wDots => (width * 8).round();
  int get hDots => (height * 8).round();
}

String _num(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
String _q(String s) => '"${s.replaceAll('"', r'\["]')}"';

Uint8List _tspl(List<String> lines) =>
    Uint8List.fromList(utf8.encode(lines.map((l) => '$l\r\n').join()));

List<String> _tsplHead(LabelSize s) => [
      'SIZE ${_num(s.width)} mm,${_num(s.height)} mm',
      'GAP ${_num(s.gap)} mm,0 mm',
      'DIRECTION 1',
      'CLS',
    ];

String _tsplCode(CodeType type, String data, int x, int y, int h) =>
    switch (type) {
      CodeType.qr => 'QRCODE $x,$y,M,4,A,0,${_q(data)}',
      CodeType.code128 => 'BARCODE $x,$y,"128",$h,1,0,2,2,${_q(data)}',
      CodeType.ean13 =>
        'BARCODE $x,$y,"EAN13",$h,1,0,2,2,${_q(data.substring(0, 12))}',
    };

Uint8List tsplSample(LabelSize s, String title, CodeType type, String data) {
  checkCode(type, data);
  final m = 16; // 2 mm
  final codeH = (s.hDots * 0.35).round().clamp(24, 200);
  return _tspl([
    ..._tsplHead(s),
    'BOX $m,$m,${s.wDots - m},${s.hDots - m},2',
    'TEXT ${m + 8},${m + 8},"3",0,1,1,${_q(title)}',
    'TEXT ${m + 8},${m + 40},"2",0,1,1,${_q('${_num(s.width)}x${_num(s.height)} mm')}',
    _tsplCode(type, data, m + 8, m + 70, codeH),
    'PRINT 1,1',
  ]);
}

Uint8List tsplCodeLabel(LabelSize s, CodeType type, String data) {
  checkCode(type, data);
  final codeH = (s.hDots * 0.5).round().clamp(24, 300);
  return _tspl([
    ..._tsplHead(s),
    _tsplCode(type, data, 16, 16, codeH),
    'PRINT 1,1',
  ]);
}

Uint8List tsplCalibrate() => _tspl(['GAPDETECT']);
Uint8List tsplSelfTest() => _tspl(['SELFTEST']);

/// ESC/POS label: the whole label as one GS v 0 image, then GS FF.
Uint8List escposSample(LabelSize s, String title, CodeType type, String data) {
  checkCode(type, data);
  final image = _blank(s.wDots, s.hDots);
  const m = 16;
  img.drawRect(image,
      x1: m,
      y1: m,
      x2: s.wDots - m - 1,
      y2: s.hDots - m - 1,
      color: _black,
      thickness: 2);
  img.drawString(image, title,
      font: s.hDots >= 240 ? img.arial48 : img.arial24,
      x: m + 8,
      y: m + 6,
      color: _black);
  final sub = '${_num(s.width)}x${_num(s.height)} mm';
  img.drawString(image, sub,
      font: img.arial14,
      x: m + 8,
      y: m + 6 + (s.hDots >= 240 ? 52 : 28),
      color: _black);
  final top = m + (s.hDots >= 240 ? 84 : 52);
  final avail = s.hDots - m - 8 - top;
  if (avail > 16) {
    final codeW = type.is2d ? avail : (s.wDots - 2 * m - 16);
    drawCode(image, type, data, m + 8, top, codeW, avail);
  }
  return _escposLabel(image);
}

Uint8List escposCodeLabel(LabelSize s, CodeType type, String data) {
  checkCode(type, data);
  final image = _blank(s.wDots, s.hDots);
  const m = 16;
  final h = s.hDots - 2 * m;
  final w = type.is2d ? h : s.wDots - 2 * m;
  drawCode(image, type, data, (s.wDots - w) ~/ 2, m, w, h);
  return _escposLabel(image);
}

Uint8List _escposLabel(img.Image image) =>
    Uint8List.fromList([..._init, ...escposRaster(image), ..._formFeed]);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

Uint8List statusQuery(LabelLang lang) => Uint8List.fromList(
    lang == LabelLang.tspl ? [0x1B, 0x21, 0x3F] : [0x10, 0x04, 0x04]);

String describeStatus(LabelLang lang, Uint8List reply) {
  final b = reply.last;
  final hex = reply.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  final String text;
  if (lang == LabelLang.tspl) {
    text = b == 0 || b == 0x20
        ? 'Ready'
        : (b & 0x01 != 0)
            ? 'Head open'
            : (b & 0x0C != 0)
                ? 'Out of paper / ribbon'
                : (b & 0x10 != 0)
                    ? 'Paused'
                    : 'Error';
  } else {
    text = (b & 0x60 != 0) ? 'Paper out / near end' : 'Paper OK';
  }
  return '$text (0x$hex)';
}
