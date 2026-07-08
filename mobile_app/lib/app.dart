import 'package:flutter/material.dart';
import 'screens/main_screen.dart';
import 'theme/app_theme.dart';

class PrinterApp extends StatelessWidget {
  const PrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '打印客户端',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      home: const MainScreen(),
    );
  }
}
