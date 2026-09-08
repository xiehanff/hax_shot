import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:get/get.dart';
import 'package:plume_ai_chat/plume_ai_chat.dart';

import '../models/hax_ai_action.dart';
import '../models/hax_ai_state.dart';
import '../services/hax_ai_prompts.dart';
import '../services/hax_ai_service.dart';

enum HaxAiSidebarMode { conversation, settings }

enum _ScrollFollowState { followingTail, userControlled }

/// Hax Shot 的 AI 侧栏宿主控制器。
///
/// 对话状态和流式请求交给 [AiChatController]，这里只保留窗口、输入框、
/// API Key 和滚动跟随等 Hax Shot 相关状态。
class HaxAiController extends GetxController {
  HaxAiController({required HaxAiService service})
    : _service = service,
      _state = service.state {
    _apiKeyController = TextEditingController(text: _state.apiKey);
    _inputController = TextEditingController();
    _inputFocusNode = FocusNode();
    _scrollController = FollowTailScrollController(
      isFollowingTail: () =>
          _scrollFollowState == _ScrollFollowState.followingTail,
    );
    _lastMessageCount = chatController.messages.length;
    _removeChatListener = chatController.addListenerId(
      AiChatUpdateId.messages,
      _handleChatChanged,
    );
  }

  static const double _kBottomFollowThreshold = 80;

  final HaxAiService _service;
  HaxAiState _state;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _inputController;
  late final FocusNode _inputFocusNode;
  late final FollowTailScrollController _scrollController;
  VoidCallback? _removeChatListener;

  HaxAiSidebarMode _mode = HaxAiSidebarMode.conversation;
  _ScrollFollowState _scrollFollowState = _ScrollFollowState.followingTail;
  ScrollDirection _userScrollDirection = ScrollDirection.idle;
  int _scrollRequestId = 0;
  bool _hasDeferredStreamingUpdate = false;
  int _lastMessageCount = 0;

  AiChatController get chatController => _service.chatController;
  HaxAiState get state => _state;
  HaxAiSidebarMode get mode => _mode;
  bool get isLoading => _state.loading || chatController.isGenerating;
  List<ChatMessage> get messages => chatController.messages;
  List<String> get followUpSuggestions => chatController.followUpSuggestions;
  TextEditingController get apiKeyController => _apiKeyController;
  TextEditingController get inputController => _inputController;
  FocusNode get inputFocusNode => _inputFocusNode;
  ScrollController get scrollController => _scrollController;
  double get sidebarWidth => 320;
  VoidCallback get onNewSession => newConversation;
  VoidCallback get onStopChat => stop;

  bool get showFollowUpSuggestions {
    if (isLoading || followUpSuggestions.isEmpty || messages.isEmpty) {
      return false;
    }
    final ChatMessage last = messages.last;
    return last.author == MessageAuthor.ai &&
        !last.isLoading &&
        last.text.trim().isNotEmpty &&
        !last.text.startsWith('❌');
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(_initializeService());
  }

  Future<void> _initializeService() async {
    try {
      await _service.init();
    } catch (_) {
      // 服务会结束 loading；设置页仍可让用户继续配置 API Key。
    } finally {
      if (!isClosed) {
        _state = _service.state;
        if (_apiKeyController.text != _state.apiKey) {
          _apiKeyController.text = _state.apiKey;
        }
        update();
      }
    }
  }

  void onApiKeyChanged(String value) {
    _service.updateApiKey(value);
    _state = _service.state;
    update();
  }

  Future<void> saveApiKey() async {
    await _service.saveApiKey(_apiKeyController.text);
    if (isClosed) return;
    _state = _service.state;
    if (_apiKeyController.text != _state.apiKey) {
      _apiKeyController.text = _state.apiKey;
    }
    update();
  }

  void showSettings() {
    _mode = HaxAiSidebarMode.settings;
    update();
  }

  void showConversation() {
    _mode = HaxAiSidebarMode.conversation;
    update();
  }

  /// 处理输入框提交，文字和剪贴板图片都走共享 package API。
  Future<void> handleSend(AiChatInput input) async {
    await sendMessage(input.text, image: input.image);
  }

  Future<void> sendText(String text) async {
    await sendMessage(text);
  }

  Future<void> sendMessage(String text, {AiImageAttachment? image}) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty && (image?.bytes.isEmpty ?? true)) return;
    if (_state.apiKey.trim().isEmpty) {
      showSettings();
      return;
    }
    if (isLoading) return;

    _resumeScrollFollowing();
    _hasDeferredStreamingUpdate = false;
    await chatController.send(
      input: AiChatInput(text: trimmed, image: image),
    );
  }

  Future<void> sendScreenshotAction({
    required HaxAiAction action,
    required Uint8List pngBytes,
  }) async {
    if (pngBytes.isEmpty) return;
    if (_state.apiKey.trim().isEmpty) {
      showSettings();
      return;
    }
    if (_state.loading) return;

    // 每次新截图开始独立的视觉上下文；正在进行的回答由 package 负责取消。
    if (chatController.isGenerating) {
      chatController.stop();
    }
    chatController.newConversation();
    _resetHostUi();

    final AiImageAttachment attachment = AiImageAttachment(
      bytes: pngBytes,
      mimeType: 'image/png',
      label: 'HaxShot screenshot',
    );
    await chatController.send(
      input: AiChatInput(text: action.label, image: attachment),
      systemPrompt: _promptFor(action),
      stopPrevious: true,
      deferHistoryCommit: true,
    );
  }

  String _promptFor(HaxAiAction action) {
    return switch (action) {
      HaxAiAction.translate => HaxAiPrompts.translate(),
      HaxAiAction.explain => HaxAiPrompts.explain(),
      HaxAiAction.deepUnderstand => HaxAiPrompts.deepUnderstand(),
    };
  }

  void stop() {
    final bool stopped = chatController.stop();
    if (!stopped && chatController.isGenerating) {
      // The provider may still be inside an uncancellable HTTP handshake. Clear
      // the host turn immediately; AiChatSession's generation guard prevents
      // late data from reviving this UI.
      chatController.newConversation();
    }
    if (_state.loading) {
      _state = _state.copyWith(loading: false);
      update();
    }
  }

  void newConversation() {
    _resetHostUi();
    chatController.newConversation();
  }

  bool handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;

    bool resumedFollowing = false;
    if (notification is UserScrollNotification) {
      _userScrollDirection = notification.direction;
      if (notification.direction == ScrollDirection.idle) return false;

      _markUserScrolled();
      if (notification.direction == ScrollDirection.reverse &&
          notification.metrics.extentAfter <= _kBottomFollowThreshold) {
        _resumeScrollFollowing();
        resumedFollowing = true;
      }
    } else if (notification is ScrollUpdateNotification &&
        _userScrollDirection == ScrollDirection.reverse &&
        notification.metrics.extentAfter <= _kBottomFollowThreshold) {
      _resumeScrollFollowing();
      resumedFollowing = true;
    }

    if (resumedFollowing) {
      _flushDeferredStreamingUpdate();
      _scheduleScrollToBottom();
    }
    return false;
  }

  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) return;
    final double delta = event.scrollDelta.dy;
    final ScrollPosition position = _scrollController.position;
    if (delta == 0 ||
        (delta < 0 && position.pixels <= position.minScrollExtent) ||
        (delta > 0 && position.pixels >= position.maxScrollExtent)) {
      return;
    }
    _markUserScrolled();
  }

  void _markUserScrolled() {
    if (_scrollFollowState == _ScrollFollowState.userControlled) return;
    _scrollFollowState = _ScrollFollowState.userControlled;
    _scrollRequestId++;
  }

  void _resumeScrollFollowing() {
    _scrollFollowState = _ScrollFollowState.followingTail;
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients ||
        _scrollFollowState != _ScrollFollowState.followingTail) {
      return;
    }
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _scheduleScrollToBottom() {
    final int requestId = _scrollRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isClosed && requestId == _scrollRequestId) {
        _scrollToBottom();
      }
    });
  }

  void _flushDeferredStreamingUpdate() {
    if (!_hasDeferredStreamingUpdate || isClosed) return;
    _hasDeferredStreamingUpdate = false;
    update();
  }

  void _handleChatChanged() {
    if (isClosed) return;

    final int messageCount = messages.length;
    final bool messageCountChanged = messageCount != _lastMessageCount;
    final bool addedMessage = messageCount > _lastMessageCount;
    final bool resetConversation = messageCount == 0 && _lastMessageCount > 0;
    _lastMessageCount = messageCount;

    if (addedMessage) {
      _resumeScrollFollowing();
      _hasDeferredStreamingUpdate = false;
    } else if (resetConversation) {
      _resetHostUi();
    }

    // 用户查看历史消息时保留最新 package 状态，避免每个流式片段都重建
    // Markdown；回到底部或本轮结束时再刷新侧栏。
    if (_scrollFollowState == _ScrollFollowState.userControlled &&
        chatController.isGenerating &&
        !messageCountChanged) {
      _hasDeferredStreamingUpdate = true;
      return;
    }

    _hasDeferredStreamingUpdate = false;
    update();
    if (addedMessage) {
      _scheduleScrollToBottom();
    }
  }

  void _resetHostUi() {
    _inputController.clear();
    _resumeScrollFollowing();
    _userScrollDirection = ScrollDirection.idle;
    _scrollRequestId++;
    _hasDeferredStreamingUpdate = false;
  }

  @override
  void onClose() {
    _removeChatListener?.call();
    _removeChatListener = null;
    _apiKeyController.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _service.dispose();
    super.onClose();
  }
}
