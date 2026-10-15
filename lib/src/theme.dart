import 'package:flutter/material.dart';

/// 与网页端 imweb/src/theme.ts 相同的 8 个种子色（SPEC v0.3.0 §4）
const List<Color> themeSeeds = [
  Color(0xFF6750A4),
  Color(0xFF0061A4),
  Color(0xFF006E1C),
  Color(0xFF9C4146),
  Color(0xFF8B5000),
  Color(0xFF006A6A),
  Color(0xFF7D5260),
  Color(0xFF4A6363),
];

/// 设置里保存的值：'system' 或 '#RRGGBB'
const String seedSystem = 'system';

String seedToString(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// 解析保存的种子色；'system' / 无效值返回 null（表示跟随系统）
Color? parseSeed(String? s) {
  if (s == null || s == seedSystem) return null;
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(s.trim());
  if (m == null) return null;
  return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

/// Material 3 tonal spot 配色
ColorScheme schemeFromSeed(Color seed, Brightness brightness) => ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
