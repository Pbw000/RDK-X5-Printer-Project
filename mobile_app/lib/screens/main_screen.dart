import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'queue_screen.dart';
import 'status_screen.dart';
import 'assistant_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1; // 0=Queue 1=Home 2=Status 3=Assistant

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).extension<AppBackground>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GlassScaffold(
      extendBody: false,
      background: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: bg.gradientColors,
          ),
        ),
      ),
      statusBarStyle: isDark
          ? GlassStatusBarStyle.light
          : GlassStatusBarStyle.dark,
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          QueueScreen(),
          HomeScreen(),
          StatusScreen(),
          AssistantScreen(),
        ],
      ),
      bottomBar: GlassTabBar.bottom(
        selectedIndex: _currentIndex,
        onTabSelected: (i) => setState(() => _currentIndex = i),
        tabs: const [
          GlassTab(icon: Icon(CupertinoIcons.list_bullet), label: '队列'),
          GlassTab(icon: Icon(CupertinoIcons.printer), label: '首页'),
          GlassTab(icon: Icon(CupertinoIcons.map), label: '状态'),
          GlassTab(icon: Icon(CupertinoIcons.chat_bubble), label: '助手'),
        ],
      ),
    );
  }
}
