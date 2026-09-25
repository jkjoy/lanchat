import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 平台保活:通过 MethodChannel 启动/停止 Android 前台服务。
///
/// 非 Android 平台调用为空操作(方法不存在时静默忽略)。
class PlatformKeepAlive {
  static const _channel = MethodChannel('lanchat_platform');
  static bool _lastState = false;

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid);

  /// 启动保活服务。返回是否成功。
  static Future<bool> start() async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod('startKeepAlive');
      _lastState = true;
      return true;
    } catch (e) {
      debugPrint('[keepalive] 启动失败: $e');
      return false;
    }
  }

  /// 停止保活服务。
  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('stopKeepAlive');
    } catch (e) {
      debugPrint('[keepalive] 停止失败: $e');
    }
    _lastState = false;
  }

  static bool get enabled => _lastState;

  /// 请求 Android 持有 MulticastLock,以便收到 UDP 广播/组播。
  /// 非 Android 平台为空操作。
  static Future<void> acquireMulticastLock() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('acquireMulticastLock');
      debugPrint('[keepalive] MulticastLock acquired');
    } catch (e) {
      debugPrint('[keepalive] acquireMulticastLock 失败: $e');
    }
  }
}