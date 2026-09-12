import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart'
    show AiChatMessageList, ChatMessage;
import 'package:window_manager/window_manager.dart';

import '../../controllers/hax_ai_controller.dart';
import 'ai_colors.dart';
import 'ai_sidebar_settings.dart';
import 'chat_bubble.dart';
import 'chat_input_bar.dart';

/// Hax Shot 的 AI 对话侧栏。
class AiSidebar extends StatelessWidget {
  const AiSidebar({required this.controller, required this.onClose, super.key});

  final HaxAiController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // 控制器由宿主持有，这里只订阅它的 update() 通知（语义等价于原来的
    // GetBuilder：GetxController.addListener 注册的就是 update() 通知的那份列表）。
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        // HaxShot uses the chat as a standalone window, so the Plume sidebar
        // content fills that window instead of reserving a PDF reader area.
        return SizedBox.expand(
          child: ColoredBox(
            color: AppColors.scaffoldBg,
            child: _AiSidebarContent(controller: controller, onClose: onClose),
          ),
        );
      },
    );
  }
}

class _AiSidebarContent extends StatelessWidget {
  const _AiSidebarContent({required this.controller, required this.onClose});

  final HaxAiController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (controller.mode == HaxAiSidebarMode.settings) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AiTitleBar(onClose: onClose),
          AiSidebarSettingsHeader(onBack: controller.showConversation),
          Expanded(
            child: AiSidebarSettingsList(
              apiKeyController: controller.apiKeyController,
              onApiKeyChanged: controller.onApiKeyChanged,
              onSaveApiKey: controller.saveApiKey,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AiTitleBar(onClose: onClose),
        Expanded(child: _buildMessageList(context)),
        ChatInputBar(
          controller: controller.inputController,
          focusNode: controller.inputFocusNode,
          isLoading: controller.isLoading,
          onSend: controller.handleSend,
          onStop: controller.onStopChat,
          onNewSession: controller.onNewSession,
          onSettingsTap: controller.showSettings,
        ),
      ],
    );
  }

  Widget _buildMessageList(BuildContext context) {
    return AiChatMessageList(
      messages: controller.messages,
      controller: controller.scrollController,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 18),
      onScrollNotification: controller.handleScrollNotification,
      onPointerSignal: controller.handlePointerSignal,
      emptyBuilder: (BuildContext context) => _buildEmptyState(context),
      messageBuilder: (BuildContext context, ChatMessage message, int index) {
        return ChatBubble(message: message);
      },
      trailingBuilder: controller.showFollowUpSuggestions
          ? (BuildContext context) => _FollowUpSuggestions(
              suggestions: controller.followUpSuggestions,
              onTap: controller.sendText,
            )
          : null,
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final bool needsApiKey = controller.state.apiKey.trim().isEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: needsApiKey
            ? _FirstUseGuide(onConfigure: controller.showSettings)
            : const Text(
                '输入消息开始对话',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
      ),
    );
  }
}

class _AiTitleBar extends StatelessWidget {
  const _AiTitleBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // 顶部条比正文暗一点，用来和消息区做区分；中间放 HaxShot 字标（GBaiMarkerPen
    // 是 assets/fonts/GBaiMarkerPen.ttf 里的马克笔手写体，见 pubspec 的 fonts）。
    // 窗口圆角由系统画（macOS 的 titled 窗口），所以这里铺满即可。
    return SizedBox(
      height: 44,
      child: ColoredBox(
        color: AppColors.titleBarBg,
        child: Stack(
          children: <Widget>[
            // 整条都是拖拽区，包括标题那一段。
            const Positioned.fill(
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
            // 字标居中，但必须让开拖拽：文字自己会吃掉 hit test，不套 IgnorePointer
            // 的话按住标题拖不动窗口。
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    'HaxShot',
                    style: TextStyle(
                      fontFamily: 'GBaiMarkerPen',
                      fontSize: 21,
                      height: 1,
                      color: AppColors.accentBright,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 16,
              child: _AiCloseButton(onPressed: onClose),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiCloseButton extends StatefulWidget {
  const _AiCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_AiCloseButton> createState() => _AiCloseButtonState();
}

class _AiCloseButtonState extends State<_AiCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: _hovered ? const Color(0xFF8A919B) : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: IconButton(
          onPressed: widget.onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          splashRadius: 14,
          icon: Icon(
            Icons.close,
            size: _hovered ? 18 : 17,
            color: _hovered ? const Color(0xFFF5F6F7) : const Color(0xFFB0B5BD),
          ),
        ),
      ),
    );
  }
}

class _FirstUseGuide extends StatelessWidget {
  const _FirstUseGuide({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.fillSubtle,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.borderSoft),
          ),
          child: const HugeIcon(
            icon: HugeIcons.strokeRoundedKey01,
            size: 28,
            strokeWidth: 1.5,
            color: AppColors.accentBright,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '先配置 API Key',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '配置后即可开始 AI 对话。',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onConfigure,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accentSurface,
            foregroundColor: AppColors.textPrimary,
          ),
          icon: const HugeIcon(
            icon: HugeIcons.strokeRoundedSettings01,
            size: 16,
            strokeWidth: 1.5,
          ),
          label: const Text('打开设置'),
        ),
      ],
    );
  }
}

class _FollowUpSuggestions extends StatelessWidget {
  const _FollowUpSuggestions({required this.suggestions, required this.onTap});

  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String text in suggestions)
            ActionChip(
              label: Text(
                text,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              onPressed: () => onTap(text),
              backgroundColor: AppColors.fillSubtle,
              side: const BorderSide(color: AppColors.borderSoft),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
