import 'package:flutter/material.dart';

import 'core/models.dart';
import 'core/chat_service.dart';
import 'ui/home_screen.dart';
import 'ui/peer_list.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 加载本机身份（设备 ID 与名称，全局唯一）。
  final self = await Identity.load();
  final service = ChatService(self: self);
  await service.start();

  runApp(LanChatApp(service: service));
}

class LanChatApp extends StatelessWidget {
  final ChatService service;

  const LanChatApp({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanChat',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: HomeScreen(service: service),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F6FED),
      brightness: brightness,
    );
    return ThemeData(colorScheme: scheme, useMaterial3: true);
  }
}