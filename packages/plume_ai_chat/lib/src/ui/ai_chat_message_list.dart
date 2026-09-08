import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/chat_message.dart';

typedef AiChatMessageBuilder =
    Widget Function(BuildContext context, ChatMessage message, int index);
typedef AiChatEmptyBuilder = Widget Function(BuildContext context);
typedef AiChatTrailingBuilder = Widget Function(BuildContext context);
typedef AiChatPointerSignalCallback = void Function(PointerSignalEvent event);

/// Reusable structure for a streaming chat message list.
///
/// Rendering stays host-defined through builders, so applications can keep
/// their own colors, Markdown renderer, icons and interaction affordances.
/// The package only owns list structure, stable message keys and scroll-event
/// plumbing used by follow-tail behavior.
class AiChatMessageList extends StatelessWidget {
  const AiChatMessageList({
    super.key,
    required this.messages,
    required this.messageBuilder,
    required this.controller,
    this.emptyBuilder,
    this.trailingBuilder,
    this.onScrollNotification,
    this.onPointerSignal,
    this.padding = EdgeInsets.zero,
  });

  final List<ChatMessage> messages;
  final AiChatMessageBuilder messageBuilder;
  final ScrollController controller;
  final AiChatEmptyBuilder? emptyBuilder;
  final AiChatTrailingBuilder? trailingBuilder;
  final NotificationListenerCallback<ScrollNotification>? onScrollNotification;
  final AiChatPointerSignalCallback? onPointerSignal;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }

    final bool hasTrailing = trailingBuilder != null;
    final Widget list = ListView.builder(
      controller: controller,
      padding: padding,
      itemCount: messages.length + (hasTrailing ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (hasTrailing && index == messages.length) {
          return trailingBuilder!(context);
        }
        final ChatMessage message = messages[index];
        return KeyedSubtree(
          key: ValueKey<String>(message.id),
          child: messageBuilder(context, message, index),
        );
      },
    );

    final Widget pointerAware = onPointerSignal == null
        ? list
        : Listener(onPointerSignal: onPointerSignal, child: list);
    return onScrollNotification == null
        ? pointerAware
        : NotificationListener<ScrollNotification>(
            onNotification: onScrollNotification!,
            child: pointerAware,
          );
  }
}
