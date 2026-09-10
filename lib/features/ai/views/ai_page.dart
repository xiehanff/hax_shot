import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/hax_ai_controller.dart';
import 'widgets/ai_colors.dart';
import 'widgets/ai_sidebar.dart';

/// AI 对话页面。显式传入控制器，避免依赖全局 Get 注册时序。
class AiPage extends StatelessWidget {
  const AiPage({required this.controller, required this.onClose, super.key});

  final HaxAiController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // Esc 一定要能退出：浮层/面板一旦拿不到键盘或按钮失灵，用户就被困住了。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.scaffoldBg,
          body: AiSidebar(controller: controller, onClose: onClose),
        ),
      ),
    );
  }
}
