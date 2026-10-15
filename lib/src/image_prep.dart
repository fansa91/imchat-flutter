import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 发送前处理好的图片
class PreparedImage {
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  const PreparedImage(this.bytes, this.mime, this.width, this.height);
}

class ImagePrepException implements Exception {
  final String message;
  const ImagePrepException(this.message);
  @override
  String toString() => message;
}

/// 长边上限与 JPEG 质量（与网页端一致）
const int maxImageEdge = 2048;
const int jpegQuality = 85;

/// 在后台 isolate 中压缩，避免卡 UI
Future<PreparedImage> prepareImage(Uint8List bytes) => Isolate.run(() => prepareImageSync(bytes));

/// 压缩规则（SPEC v0.3.0 §1）：
/// - GIF 原样上传，只读出宽高；
/// - PNG 含透明像素：保持 PNG（超过长边上限时缩小）；
/// - 其他（JPEG / WebP / 不透明 PNG 等）：按 EXIF 方向摆正，长边缩到 2048 以内，JPEG 质量 85。
PreparedImage prepareImageSync(Uint8List bytes) {
  final format = img.findFormatForData(bytes);
  if (format == img.ImageFormat.gif) {
    final info = img.GifDecoder().startDecode(bytes);
    if (info == null) throw const ImagePrepException('无法识别的 GIF 图片');
    return PreparedImage(bytes, 'image/gif', info.width, info.height);
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const ImagePrepException('不支持的图片格式');
  var image = img.bakeOrientation(decoded);
  final long = image.width > image.height ? image.width : image.height;
  if (long > maxImageEdge) {
    final landscape = image.width >= image.height;
    image = img.copyResize(
      image,
      width: landscape ? maxImageEdge : null,
      height: landscape ? null : maxImageEdge,
      interpolation: img.Interpolation.average,
    );
  }
  if (format == img.ImageFormat.png && _hasTransparency(image)) {
    final out = long > maxImageEdge ? img.encodePng(image, level: 6) : bytes;
    return PreparedImage(out, 'image/png', image.width, image.height);
  }
  if (image.hasAlpha) {
    // 去掉 alpha 通道（JPEG 不支持）
    image = image.convert(numChannels: 3);
  }
  return PreparedImage(img.encodeJpg(image, quality: jpegQuality), 'image/jpeg', image.width, image.height);
}

bool _hasTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  final max = image.maxChannelValue;
  for (final p in image) {
    if (p.a < max) return true;
  }
  return false;
}
