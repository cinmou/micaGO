import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _avatarDirectory() async => Directory(
  '${(await getApplicationSupportDirectory()).path}/linux-notification-avatars',
);

/// Cache a centered circular PNG because desktop notification icons are square.
Future<String?> circularLinuxNotificationAvatar(String path) async {
  ui.Codec? codec;
  ui.Image? image;
  ui.Image? rounded;
  ui.Picture? picture;
  try {
    final bytes = await File(path).readAsBytes();
    final directory = await _avatarDirectory();
    final file = File('${directory.path}/${sha256.convert(bytes)}.png');
    if (await file.exists()) return file.path;
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 256,
      allowUpscaling: false,
    );
    image = (await codec.getNextFrame()).image;
    final side = math.min(image.width, image.height).toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const destination = ui.Rect.fromLTWH(0, 0, 128, 128);
    canvas.clipPath(ui.Path()..addOval(destination));
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        (image.width - side) / 2,
        (image.height - side) / 2,
        side,
        side,
      ),
      destination,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    picture = recorder.endRecording();
    rounded = await picture.toImage(128, 128);
    final data = await rounded.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await temporary.rename(file.path);
    return file.path;
  } catch (_) {
    return null;
  } finally {
    rounded?.dispose();
    picture?.dispose();
    image?.dispose();
    codec?.dispose();
  }
}

Future<void> clearLinuxNotificationAvatars() async {
  try {
    final directory = await _avatarDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // The cache can be removed on the next successful notification cleanup.
  }
}
