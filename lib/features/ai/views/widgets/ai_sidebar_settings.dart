import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart' show DeepSeekBackend;

import 'ai_colors.dart';

class AiSidebarSettingsHeader extends StatelessWidget {
  const AiSidebarSettingsHeader({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBack,
            tooltip: '返回',
            style: IconButton.styleFrom(
              minimumSize: const Size(30, 30),
              maximumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              foregroundColor: AppColors.textSecondary,
            ),
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedArrowLeft01,
              size: 16,
              strokeWidth: 1.5,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '设置',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class AiSidebarSettingsList extends StatelessWidget {
  const AiSidebarSettingsList({
    super.key,
    required this.apiKeyController,
    required this.onApiKeyChanged,
    required this.onSaveApiKey,
    this.shrinkWrap = false,
  });

  final TextEditingController apiKeyController;
  final ValueChanged<String> onApiKeyChanged;
  final Future<void> Function() onSaveApiKey;

  /// 在底部弹窗等有限高度容器内使用时置 true。
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 18),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      children: <Widget>[
        const _ModelInfoCard(),
        ApiKeyCard(
          title: 'DeepSeek',
          hintText: '输入 DeepSeek API Key',
          controller: apiKeyController,
          onChanged: onApiKeyChanged,
          onSave: onSaveApiKey,
        ),
      ],
    );
  }
}

class _ModelInfoCard extends StatelessWidget {
  const _ModelInfoCard();

  @override
  Widget build(BuildContext context) {
    const String modelId = DeepSeekBackend.defaultModel;
    const String label = 'DeepSeek Vision';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.fillSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '当前 AI 模型',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            modelId,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class ApiKeyCard extends StatefulWidget {
  const ApiKeyCard({
    super.key,
    required this.title,
    required this.hintText,
    required this.controller,
    required this.onChanged,
    required this.onSave,
  });

  final String title;
  final String hintText;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onSave;

  @override
  State<ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends State<ApiKeyCard> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.fillSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: widget.controller,
            onChanged: widget.onChanged,
            obscureText: _obscure,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: const TextStyle(
                color: AppColors.textHint,
                fontSize: 13,
              ),
              filled: true,
              fillColor: AppColors.fieldBg,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderSoft),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderSoft),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderFocused),
              ),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                tooltip: _obscure ? '显示' : '隐藏',
                icon: HugeIcon(
                  icon: _obscure
                      ? HugeIcons.strokeRoundedViewOffSlash
                      : HugeIcons.strokeRoundedView,
                  size: 16,
                  strokeWidth: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                widget.onSave();
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentSurface,
                foregroundColor: AppColors.textPrimary,
              ),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
