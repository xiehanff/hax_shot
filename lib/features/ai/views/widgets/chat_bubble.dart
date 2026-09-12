import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart'
    show GptMarkdownConfig;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:loading_indicator/loading_indicator.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart'
    show ChatMessage, MessageAuthor;

import 'ai_colors.dart';

/// 聊天 markdown 统一字体：正文（含标题、思考面板）使用 OPPO Sans，
/// 代码（行内与代码块）使用 GoogleSansMono。
const String kMarkdownFontFamily = 'OPPO Sans 4.0';
const String kCodeFontFamily = 'GoogleSansMono';

const List<String> kMarkdownFontFallback = <String>[
  'Microsoft YaHei',
  'Microsoft YaHei UI',
  '微软雅黑',
];

/// 聊天正文 markdown 主题：保持应用默认标题样式，关闭 h1 后自动
/// 附加的分割线（流式回答中大量标题会带出满屏分割线），并把模型
/// 输出的 `---` 水平线弱化为细淡线。
GptMarkdownThemeData _chatMarkdownThemeData(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final TextTheme textTheme = theme.textTheme;
  return GptMarkdownThemeData(brightness: theme.brightness).copyWith(
    highlightColor: theme.colorScheme.onSurfaceVariant.withAlpha(50),
    h1: textTheme.headlineLarge?.copyWith(fontFamily: kMarkdownFontFamily),
    h2: textTheme.headlineMedium?.copyWith(fontFamily: kMarkdownFontFamily),
    h3: textTheme.headlineSmall?.copyWith(fontFamily: kMarkdownFontFamily),
    h4: textTheme.titleLarge?.copyWith(fontFamily: kMarkdownFontFamily),
    h5: textTheme.titleMedium?.copyWith(fontFamily: kMarkdownFontFamily),
    h6: textTheme.titleSmall?.copyWith(fontFamily: kMarkdownFontFamily),
    autoAddDividerLineAfterH1: false,
    hrLineThickness: 1,
    hrLineColor: AppColors.borderVisible,
    hrLinePadding: const EdgeInsets.symmetric(vertical: 6),
  );
}

/// 思考面板 markdown 主题：在正文主题基础上把标题收敛为小字号，
/// 避免推理文本中的标题撑破 12px 的紧凑面板。
GptMarkdownThemeData _reasoningMarkdownThemeData(BuildContext context) {
  const Color textColor = Color(0xFFD0D5DD);
  const TextStyle heading = TextStyle(
    color: textColor,
    fontSize: 13,
    height: 1.5,
    fontWeight: FontWeight.w600,
    fontFamily: kMarkdownFontFamily,
  );
  return _chatMarkdownThemeData(context).copyWith(
    h1: heading.copyWith(fontSize: 13.5, fontWeight: FontWeight.w700),
    h2: heading,
    h3: heading.copyWith(fontSize: 12.5),
    h4: heading.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
    h5: heading.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
    h6: heading.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
  );
}

/// 渲染为空的水平线组件：替换 gpt_markdown 默认组件集中的 [HrLine]，
/// 让模型输出的 `---` 不产生分割线。
///
/// 在组件层隐藏而非预处理文本：块级解析按组件列表顺序匹配，
/// [CodeBlockMd] 优先级更高，代码块内的 `---`（如 YAML 分隔符）
/// 属于代码块内容，不会进入本组件，展示与原文一致。
class _HiddenHrLine extends BlockMd {
  @override
  String get expString => HrLine().expString;

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) =>
      const SizedBox.shrink();
}

/// 聊天 markdown 的组件集：默认组件中的水平线替换为空渲染。
final List<MarkdownComponent> _chatMarkdownComponents = MarkdownComponent
    .globalComponents
    .map(
      (MarkdownComponent component) =>
          component is HrLine ? _HiddenHrLine() : component,
    )
    .toList();

/// 聊天 markdown 的共享渲染：统一字体、代码块与行内代码样式。
Widget _buildChatMarkdown(
  BuildContext context,
  String data, {
  required TextStyle style,
  required GptMarkdownThemeData themeData,
}) {
  return GptMarkdownTheme(
    gptThemeData: themeData,
    child: GptMarkdown(
      data,
      components: _chatMarkdownComponents,
      style: style.copyWith(
        // markdown 文本统一使用 OPPO Sans，缺字时回退系统中文字体。
        fontFamily: kMarkdownFontFamily,
        fontFamilyFallback: kMarkdownFontFallback,
      ),
      codeBuilder:
          (BuildContext context, String name, String code, bool closed) {
            final String language = name.isNotEmpty ? name : 'plaintext';
            return CodeBlock(language: language, code: code, closed: closed);
          },
      highlightBuilder: (BuildContext context, String text, TextStyle style) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: AppColors.accentSurface,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: style.copyWith(
              // 行内代码块高度收紧：否则继承正文 height 2.0 会撑破
              // WidgetSpan 行高计算，导致相邻行粘连。
              height: 1.2,
              fontFamily: kCodeFontFamily,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      },
    ),
  );
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final bool isHuman = message.author == MessageAuthor.human;

    return Container(
      margin: EdgeInsets.only(bottom: 12, left: isHuman ? 32 : 0, right: 0),
      child: Column(
        crossAxisAlignment: isHuman
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isHuman ? AppColors.accentSurface : AppColors.surfaceBg,
              borderRadius: isHuman
                  ? const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                      topRight: Radius.zero,
                    )
                  : BorderRadius.circular(12),
            ),
            child: isHuman ? _buildHumanContent() : _buildAiContent(context),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return const SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 20,
            height: 20,
            child: LoadingIndicator(
              indicatorType: Indicator.ballPulse,
              colors: <Color>[Color(0xB3FFFFFF)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHumanContent() {
    final Widget text = Text(
      message.text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 14,
        height: 2.0,
      ),
    );
    final Uint8List? imageBytes = message.imageBytes;
    if (imageBytes == null || imageBytes.isEmpty) {
      return text;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160, maxHeight: 160),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              imageBytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
        if (message.text.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          text,
        ],
      ],
    );
  }

  Widget _buildAiContent(BuildContext context) {
    final String reasoning = message.reasoning?.trim() ?? '';
    final String text = message.text.trim();
    final List<Widget> children = <Widget>[];
    if (reasoning.isNotEmpty) {
      children.add(
        ReasoningPanel(text: reasoning, isLoading: message.isLoading),
      );
    }
    if (text.isNotEmpty) {
      children.add(_buildAiMarkdown(context));
    } else if (message.isLoading && reasoning.isEmpty) {
      children.add(_buildLoading());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildAiMarkdown(BuildContext context) {
    return _buildChatMarkdown(
      context,
      message.text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 14,
        height: 2.0,
      ),
      themeData: _chatMarkdownThemeData(context),
    );
  }
}

/// 流式推理过程的独立深色容器。
///
/// 内容按 markdown 渲染。默认折叠为最多八行并渐隐截断；内容超出后
/// 由用户点击按钮展开，避免复杂思考时侧栏只剩一个 loading 占位，
/// 也避免推理文本撑满整个对话区。
class ReasoningPanel extends StatefulWidget {
  const ReasoningPanel({super.key, required this.text, this.isLoading = false});

  final String text;
  final bool isLoading;

  @override
  State<ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<ReasoningPanel> {
  static const int _maxLines = 8;
  static const TextStyle _textStyle = TextStyle(
    color: Color(0xFFD0D5DD),
    fontSize: 12,
    height: 1.5,
    fontFamily: kMarkdownFontFamily,
    fontFamilyFallback: kMarkdownFontFallback,
  );

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 以纯文本测量估算内容是否超出八行（与展开状态无关，
        // 展开后仍需显示“收起”按钮）；渲染路径再区分展开/折叠。
        final bool hasOverflow = _measureHasOverflow(constraints);

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
          decoration: BoxDecoration(
            color: const Color(0xFF20242B),
            border: Border.all(color: AppColors.borderSoft),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: Color(0xFF98A2B3),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '思考过程',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.isLoading) ...<Widget>[
                    const SizedBox(width: 8),
                    const Text(
                      '思考中…',
                      style: TextStyle(color: Color(0xFF7F8998), fontSize: 11),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              _buildReasoningBody(context, hasOverflow),
              if (hasOverflow) ...<Widget>[
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentBright,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_expanded ? '收起' : '展开全部'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 以源文本行数估算是否超出折叠上限，决定按钮显隐与截断渲染。
  bool _measureHasOverflow(BoxConstraints constraints) {
    final double maxTextWidth = constraints.maxWidth.isFinite
        ? (constraints.maxWidth - 24).clamp(1, double.infinity)
        : 640;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: widget.text, style: _textStyle),
      textDirection: TextDirection.ltr,
      maxLines: _maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxTextWidth);
    return painter.didExceedMaxLines;
  }

  /// 折叠态：纯文本轻量渲染，截断八行并渐隐，不构建完整 Markdown。
  ///
  /// 流式期间推理文本不断增长，折叠态若每次都走 Markdown 全量解析
  /// 是显著 CPU 热区（视觉上仅展示八行，却解析全部内容）；只有用户
  /// 点击展开后才完整渲染 Markdown。
  Widget _buildReasoningBody(BuildContext context, bool hasOverflow) {
    if (_expanded) {
      return _buildChatMarkdown(
        context,
        widget.text,
        style: _textStyle,
        themeData: _reasoningMarkdownThemeData(context),
      );
    }
    final Widget text = Text(
      widget.text,
      style: _textStyle,
      maxLines: _maxLines,
      overflow: TextOverflow.clip,
    );
    if (!hasOverflow) {
      return text;
    }
    final double maxCollapsedHeight =
        _maxLines * _textStyle.fontSize! * _textStyle.height!;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Colors.white, Colors.white, Color(0x00FFFFFF)],
        stops: <double>[0, 0.85, 1],
      ).createShader(bounds),
      child: ClipRect(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxCollapsedHeight),
          child: text,
        ),
      ),
    );
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({
    super.key,
    required this.language,
    required this.code,
    this.closed = true,
  });

  final String language;
  final String code;

  /// 代码围栏是否已闭合。
  ///
  /// 流式期间未闭合的代码块以等宽纯文本渲染，避免每个 preview 都对
  /// 不断增长的代码重新做语法高亮解析；围栏闭合后才切换为高亮渲染。
  final bool closed;

  static const TextStyle _codeTextStyle = TextStyle(
    fontSize: 13,
    height: 1.5,
    fontFamily: kCodeFontFamily,
    fontFamilyFallback: kMarkdownFontFallback,
  );

  static const Map<String, String> _langMap = <String, String>{
    'dart': 'dart',
    'python': 'python',
    'py': 'python',
    'javascript': 'javascript',
    'js': 'javascript',
    'typescript': 'typescript',
    'ts': 'typescript',
    'java': 'java',
    'kotlin': 'kotlin',
    'swift': 'swift',
    'c': 'c',
    'cpp': 'cpp',
    'c++': 'cpp',
    'go': 'go',
    'rust': 'rust',
    'ruby': 'ruby',
    'php': 'php',
    'shell': 'bash',
    'bash': 'bash',
    'sh': 'bash',
    'sql': 'sql',
    'yaml': 'yaml',
    'yml': 'yaml',
    'json': 'json',
    'xml': 'xml',
    'html': 'xml',
    'css': 'css',
    'markdown': 'markdown',
    'md': 'markdown',
  };

  @override
  Widget build(BuildContext context) {
    final String hlLang =
        _langMap[language.toLowerCase()] ?? language.toLowerCase();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF282C34),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF21252B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Text(
              language,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: closed
                ? HighlightView(
                    code,
                    language: hlLang,
                    theme: atomOneDarkTheme,
                    textStyle: _codeTextStyle,
                  )
                : Text(code, style: _codeTextStyle),
          ),
        ],
      ),
    );
  }
}
