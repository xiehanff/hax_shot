import 'package:flutter/widgets.dart';

/// Keeps a streaming conversation pinned to the bottom during layout.
///
/// When the host says it is following the tail and content grows, the scroll
/// offset is corrected inside the viewport's dimension-correction pass. This
/// avoids a post-frame jump where one stale frame is painted before scrolling.
class FollowTailScrollController extends ScrollController {
  FollowTailScrollController({required this.isFollowingTail});

  final ValueGetter<bool> isFollowingTail;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics? physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _FollowTailScrollPosition(
      physics: physics ?? const ClampingScrollPhysics(),
      context: context,
      oldPosition: oldPosition,
      isFollowingTail: isFollowingTail,
    );
  }
}

class _FollowTailScrollPosition extends ScrollPositionWithSingleContext {
  _FollowTailScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.isFollowingTail,
  });

  final ValueGetter<bool> isFollowingTail;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldDimensions,
    ScrollMetrics newDimensions,
  ) {
    if (isFollowingTail() && newDimensions.maxScrollExtent - pixels > 0.5) {
      correctPixels(newDimensions.maxScrollExtent);
      return false;
    }
    return super.correctForNewDimensions(oldDimensions, newDimensions);
  }
}
