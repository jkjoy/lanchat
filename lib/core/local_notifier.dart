import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知:收到新消息时弹出系统通知(Android/iOS/macOS)。
///
/// 多平台统一用 [FlutterLocalNotificationsPlugin] 初始化;Android
/// 需要 13+ 的通知运行时权限(调用方在开启时请求)。桌面(Windows/Linux)
/// 不初始化(插件不可用),静默返回 false。
class LocalNotifier {
  static final LocalNotifier instance = LocalNotifier._();
  LocalNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<bool> init() async {
    if (_initialized) return true;
    try {
      // Android 初始化(图标用应用自身图标)。
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings();
      const settings = InitializationSettings(
        android: androidInit,
        iOS: iosInit,
        macOS: iosInit,
      );
      await _plugin.initialize(settings: settings);
      _initialized = true;
      return true;
    } catch (e) {
      debugPrint('[notify] 初始化失败: $e');
      return false;
    }
  }

  /// 请求 Android 13+ 通知权限(静默:拒绝不抛错)。
  Future<void> requestPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[notify] 请求权限失败: $e');
    }
  }

  /// 展示一条新消息通知。
  Future<void> show(String title, String body) async {
    if (!_initialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'lanchat_messages',
        '聊天消息',
        channelDescription: '收到的新消息',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
        macOS: iosDetails,
      );
await _plugin.show(
      id: DateTime.now().millisecond % 10000,
      title: title,
      body: body,
      notificationDetails: details,
    );
    } catch (e) {
      debugPrint('[notify] 发送失败: $e');
    }
  }

  /// 各平台支持性(桌面 Windows/Linux 不支持)。
  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS);
}