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
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF101418) : const Color(0xFFF4F6FA),

      // 卡片/浮层:统一圆角与低阴影
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF1A2027) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? const Color(0xFF1A2027) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      // 输入框:填充式圆角,聚焦主色描边
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1E252D) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(
              color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),

      // 列表项:更圆润的选中态
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),

      // AppBar:融入背景,弱化分割感
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor:
            isDark ? const Color(0xFF14191F) : const Color(0xFFF4F6FA),
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
      ),

      dividerTheme: DividerThemeData(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}