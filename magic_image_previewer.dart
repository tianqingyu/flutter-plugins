import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:resource/resource.image.dart';

/// 图片预览页面（基于PageView的实现）
/// 
/// 1. 支持预览单张、多张图片
/// 2. 支持预览本地、网络图片
/// 3. 支持缩放、移动图片
/// 4. 支持左右滑动切换图片（多张图片的场景）
/// 5. 支持单击关闭预览页面
/// 6. 支持双击回到默认屏宽大小
/// 
/// 注1：图片默认设置为屏宽
/// 注2：图片缩放的最小倍率固定为0.5
/// 注3：从这篇文章 https://zhuanlan.zhihu.com/p/410565706 获取灵感
/// 
class MagicImagePreviewer extends StatefulWidget {
  MagicImagePreviewer({
    Key key,
    this.urls,
    this.maxScale = 3,
    this.initIndex = 0,
  }) : assert(maxScale != null && maxScale > 1),
       assert(urls != null && urls.isNotEmpty),
       super(key: key);

  final int initIndex;
  final double maxScale;
  final List<String> urls;

  @override
  _MagicImagePreviewerState createState() => _MagicImagePreviewerState();
}

class _MagicImagePreviewerState extends State<MagicImagePreviewer> {
  PageController pageController;
  ValueNotifier<int> pageIndexNotifier;

  @override
  void initState() {
    super.initState();
    pageController = PageController(initialPage: widget.initIndex);
    pageIndexNotifier = ValueNotifier(widget.initIndex);
  }

  @override
  void dispose() {
    pageController.dispose();
    pageIndexNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: buildPageView(),
            ),
            // 按钮 - 关闭
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                color: Color(0x77000000),
                child: IconButton(
                  icon: Image.asset(ImageRes.CLOSE_WHITE),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            // 当前index/总数
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                color: Color(0x77000000),
                width: 50,
                height: 50,
                child: Center(
                  child: ValueListenableBuilder(
                    valueListenable: pageIndexNotifier,
                    builder: (context, index, _) {
                      return Text(
                        '${index + 1}/${widget.urls.length}',
                        style: TextStyle(color: Colors.white),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPageView() {
    return PageView.builder(
      controller: pageController,
      itemCount: widget.urls.length,
      itemBuilder: (_, i) {
        return buildImageView(widget.urls[i]);
      },
      onPageChanged: (index) {
        pageIndexNotifier.value = index;
      },
    );
  }

  Widget buildImageView(String url) {
    return _ImageWrapper(
      src: url,
      minScale: 0.5,
      maxScale: widget.maxScale,
      pageController: pageController,
    );
  }
}

/// _ImageWrapper
/// ---------------------------------------------------------------------------
class _ImageWrapper extends StatefulWidget {
  _ImageWrapper({
    Key key,
    this.src,
    this.minScale,
    this.maxScale,
    this.pageController,
  }) : super(key: key);

  final String src;
  final double minScale;
  final double maxScale;
  final PageController pageController;

  @override
  _ImageWrapperState createState() => _ImageWrapperState();
}

class _ImageWrapperState extends State<_ImageWrapper> {
  Map<Type, GestureRecognizerFactory> gestures;

  double imageWidth;

  /// 图片缩放后，超出原长度的大小，再取一半
  double halfScaledWidth = 0;

  /// 围绕中心点进行缩放和位移
  double initScale = 1;
  double centerScale = 1;
  Offset initTranslate = Offset.zero;
  Offset centerTranslate = Offset.zero;

  Drag drag;
  ScrollHoldController hold;
  PointerEvent pointerEvent;

  @override
  void initState() {
    super.initState();

    // 1. 清空（阻止）PageView的HorizontalDrag手势
    // 2. 解决PageView在松手后，滑动这段时间，子Widget不响应手势的问题
    widget.pageController.position.context.setCanDrag(false);
    widget.pageController.position.context.setIgnorePointer(false);

    gestures = {
      _AlwaysAllowScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_AlwaysAllowScaleGestureRecognizer>(
        () => _AlwaysAllowScaleGestureRecognizer(
          debugOwner: this,
          onSetPointerEvent: (event) {
            pointerEvent = event;
          },
        ),
        (recognizer) {
          recognizer
            ..onStart = onScaleStart
            ..onUpdate = onScaleUpdate
            ..onEnd = (details) => onScaleEnd(details, recognizer);
        },
      ),
      TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
        () => TapGestureRecognizer(debugOwner: this),
        (recognizer) {
          recognizer..onTap = onTap;
        },
      ),
      DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
        () => DoubleTapGestureRecognizer(debugOwner: this),
        (recognizer) {
          recognizer..onDoubleTap = onDoubleTap;
        },
      ),
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    imageWidth = MediaQuery.of(context).size.width;
  }

  @override
  Widget build(BuildContext context) {
    final transform = Matrix4.identity()
      ..scale(centerScale)
      ..translate(centerTranslate.dx / centerScale, centerTranslate.dy / centerScale);
    return RawGestureDetector(
      gestures: gestures,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(
        child: Transform(
          transform: transform,
          alignment: Alignment.center,
          child: buildImage(),
        ),
      ),
    );
  }

  Widget buildImage() {
    if (widget.src.startsWith('http')) {
      return buildNetworkImage();
    }
    if (widget.src.startsWith('/')) {
      return buildFileImage();
    }
    return buildAssertImage();
  }

  Widget buildNetworkImage() {
    return CachedNetworkImage(
      fit: BoxFit.fitWidth,
      imageUrl: widget.src,
      placeholder: buildLoading,
    );
  }

  Widget buildFileImage() {
    return Image.file(
      File(widget.src),
      fit: BoxFit.fitWidth,
    );
  }

  Widget buildAssertImage() {
    return Image.asset(
      widget.src,
      fit: BoxFit.fitWidth,
    );
  }

  Widget buildLoading(BuildContext context, String url) {
    return Center(
      child: SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  /// 缩放和移动图片
  /// 
  void onScaleStart(ScaleStartDetails details) {
    initScale = centerScale;
    initTranslate = details.localFocalPoint - initTranslate;
  }
  void onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      // 两指：缩放图片
      if (details.pointerCount > 1) {
        centerScale = initScale * details.scale;
        if (centerScale < widget.minScale) centerScale = widget.minScale;
        if (centerScale > widget.maxScale) centerScale = widget.maxScale;

        halfScaledWidth = imageWidth * (centerScale - 1) / 2;
      }
      // 单指：移动图片
      else {
        centerTranslate = details.localFocalPoint - initTranslate;

        if (isMovePageView(centerTranslate.dx)) {
          if (centerScale >= 1) {
            final sign = isMoveLeft(centerTranslate.dx) ? -1 : 1;
            centerTranslate = Offset(halfScaledWidth * sign, centerTranslate.dy);
          } else {
            centerTranslate = Offset(0, centerTranslate.dy);
          }

          onHorizontalDragStart();
          onHorizontalDragUpdate();
        }
        // 触发DragEnd是为了解决，当已经移动了PageView时，不松开手指，无法再移回边缘的问题
        else {
          onHorizontalDragEnd();
        }
      }
    });
  }
  void onScaleEnd(ScaleEndDetails details, _AlwaysAllowScaleGestureRecognizer recognizer) {
    initScale = centerScale;
    initTranslate = centerTranslate;
    onHorizontalDragEnd(recognizer);
  }
  bool isMoveLeft(double centerOffset) => centerOffset <= 0;
  bool isMovePageView(double centerOffset) => centerOffset.abs() > halfScaledWidth;

  /// 左右滑动切换图片
  /// 
  void onHorizontalDragStart() {
    if (drag != null)
      return;
    final details = DragStartDetails(
      sourceTimeStamp: pointerEvent.timeStamp,
      globalPosition: pointerEvent.position,
      localPosition: pointerEvent.localPosition,
    );
    hold = widget.pageController.position.hold(disposeHold);
    drag = widget.pageController.position.drag(details, disposeDrag);
  }
  void onHorizontalDragUpdate() {
    if (drag == null)
      return;
    final details = DragUpdateDetails(
      sourceTimeStamp: pointerEvent.timeStamp,
      delta: Offset(pointerEvent.localDelta.dx, 0),
      primaryDelta: pointerEvent.localDelta.dx,
      globalPosition: pointerEvent.position,
      localPosition: pointerEvent.localPosition,
    );
    drag.update(details);
  }
  void onHorizontalDragEnd([_AlwaysAllowScaleGestureRecognizer recognizer]) {
    if (drag == null)
      return;
    if (recognizer == null) {
      drag.end(DragEndDetails(primaryVelocity: 0));
      return;
    }
    final tracker = recognizer._velocityTrackers[pointerEvent.pointer];
    final estimate = tracker.getVelocityEstimate();
    if (estimate != null && recognizer.isFlingGesture(estimate, tracker.kind)) {
      final velocity = Velocity(pixelsPerSecond: estimate.pixelsPerSecond).clampMagnitude(kMinFlingVelocity, kMaxFlingVelocity);
      drag.end(DragEndDetails(velocity: velocity, primaryVelocity: velocity.pixelsPerSecond.dx));
    } else {
      drag.end(DragEndDetails(primaryVelocity: 0));
    }
  }
  void disposeHold() {
    hold = null;
  }
  void disposeDrag() {
    drag = null;
  }

  void onTap() {
    Navigator.pop(context);
  }
  void onDoubleTap() {
    setState(() {
      centerScale = centerScale > 1 ? 1 : 2;
      initScale = centerScale;
      initTranslate = Offset.zero;
      centerTranslate = Offset.zero;
      halfScaledWidth = imageWidth * (centerScale - 1) / 2;
    });
  }
}

/// _AlwaysAllowScaleGestureRecognizer
/// ---------------------------------------------------------------------------
class _AlwaysAllowScaleGestureRecognizer extends ScaleGestureRecognizer {
  _AlwaysAllowScaleGestureRecognizer({
    Object debugOwner,
    PointerDeviceKind kind,
    DragStartBehavior dragStartBehavior = DragStartBehavior.down,
    this.onSetPointerEvent,
  }) : super(debugOwner: debugOwner, kind: kind, dragStartBehavior: dragStartBehavior);

  final ValueSetter<PointerEvent> onSetPointerEvent;
  final Map<int, VelocityTracker> _velocityTrackers = <int, VelocityTracker>{};

  @override
  void addAllowedPointer(PointerEvent event) {
    super.addAllowedPointer(event);
    _velocityTrackers[event.pointer] = VelocityTracker.withKind(event.kind);
  }

  @override
  void rejectGesture(int pointer) {
    acceptGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    onSetPointerEvent?.call(event);
    if (!event.synthesized && (event is PointerDownEvent || event is PointerMoveEvent)) {
      final tracker = _velocityTrackers[event.pointer];
      tracker.addPosition(event.timeStamp, event.localPosition);
    }
  }

  @override
  void dispose() {
    _velocityTrackers.clear();
    super.dispose();
  }

  bool isFlingGesture(VelocityEstimate estimate, PointerDeviceKind kind) {
    final minVelocity = kMinFlingVelocity;
    final minDistance = computeHitSlop(kind);
    return estimate.pixelsPerSecond.dx.abs() > minVelocity && estimate.offset.dx.abs() > minDistance;
  }
}