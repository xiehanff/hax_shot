import 'package:flutter/material.dart';

import 'annotation.dart';

/// Interactive editing surface for the text annotation currently being typed.
///
/// The editor is an overlay only. Its border and corner handles are never
/// painted by [ScreenshotCanvas], so they cannot leak into the exported PNG.
final class TextAnnotationEditor extends StatelessWidget {
  const TextAnnotationEditor({
    required this.annotation,
    required this.controller,
    required this.focusNode,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    super.key,
  });

  final ScreenshotAnnotation annotation;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<TextResizeHandle> onResizeStart;
  final void Function(TextResizeHandle handle, Offset delta) onResizeUpdate;
  final ValueChanged<TextResizeHandle> onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final showFrame = annotation.text.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: showFrame
                  ? Border.all(color: annotation.color, width: 1.5)
                  : null,
              color: showFrame
                  ? Colors.black.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: annotation.color,
                fontSize: annotation.fontSize,
                height: 1,
              ),
              cursorColor: annotation.color,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        if (showFrame) ...[
          _Handle(
            handle: TextResizeHandle.topLeft,
            alignment: Alignment.topLeft,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _Handle(
            handle: TextResizeHandle.topRight,
            alignment: Alignment.topRight,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _Handle(
            handle: TextResizeHandle.bottomLeft,
            alignment: Alignment.bottomLeft,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _Handle(
            handle: TextResizeHandle.bottomRight,
            alignment: Alignment.bottomRight,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
        ],
      ],
    );
  }
}

final class _Handle extends StatelessWidget {
  const _Handle({
    required this.handle,
    required this.alignment,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  final TextResizeHandle handle;
  final Alignment alignment;
  final ValueChanged<TextResizeHandle> onResizeStart;
  final void Function(TextResizeHandle handle, Offset delta) onResizeUpdate;
  final ValueChanged<TextResizeHandle> onResizeEnd;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        key: ValueKey('text-resize-${handle.name}'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onResizeStart(handle),
        onPanUpdate: (details) => onResizeUpdate(handle, details.delta),
        onPanEnd: (_) => onResizeEnd(handle),
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black54, width: 1),
            ),
            child: const SizedBox.square(dimension: 8),
          ),
        ),
      ),
    );
  }
}
