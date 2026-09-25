import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 平台存储服务:将接收到的文件复制到公共目录(Android 相册/Downloads、macOS 桌面等)。
///
/// 纯 Dart 平台兼容层:
/// - Android:使用 MethodChannel `lanchat_platform/save_to_public` 调用 Kotlin 原生代码
/// - macOS:直接复制到 ~/Downloads
/// - Windows:直接复制到 ~/Downloads
/// - iOS:复制到应用文档目录(系统相册不在跨平台范围内)
class PlatformStorage {
  static const _channel = MethodChannel('lanchat_platform');

  /// 将 [sourcePath] 文件以 [name] 保存到公共目录。返回最终路径。
  static Future<String> saveToPublic(String sourcePath, String name) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw FileSystemException('文件不存在', sourcePath);
    }

    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<String>(
          'saveToPublic',
          {'sourcePath': sourcePath, 'name': name},
        );
        return result ?? sourcePath;
      } catch (e) {
        debugPrint('[storage] MethodChannel 失败,退回复制到 Downloads: $e');
        return _copyToDownloads(sourcePath, name);
      }
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return _copyToDownloads(sourcePath, name);
    } else {
      // iOS:留在应用文档目录。
      return sourcePath;
    }
  }

  static Future<String> _copyToDownloads(
      String sourcePath, String name) async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    final downloads = Directory(
        '$home${Platform.pathSeparator}Downloads');
    if (!await downloads.exists()) {
      await downloads.create(recursive: true);
    }
    var target = '${downloads.path}${Platform.pathSeparator}$name';
    // 避免同名覆盖。
    final src = File(sourcePath);
    var counter = 1;
    while (await File(target).exists()) {
      final dot = name.lastIndexOf('.');
      if (dot > 0) {
        target =
            '${downloads.path}${Platform.pathSeparator}${name.substring(0, dot)}_$counter${name.substring(dot)}';
      } else {
        target = '${downloads.path}${Platform.pathSeparator}${name}_$counter';
      }
      counter++;
    }
    await src.copy(target);
    debugPrint('[storage] 已保存到 $target');
    return target;
  }
}