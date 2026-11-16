// PixelMotion：讓逐格像素圖的部件依事件或固定節奏換整數格姿勢。
//
// 契約在元件庫規格的 4.1。要點：
// - 姿勢只在計時器觸發、而且算出的姿勢跟上一個不同時才重畫；靜止時沒有計時器、不排下一幀。
// - 時間由觸發後經過的姿勢間隔數累計（第 n 次為 n × poseInterval），不讀 Stopwatch，
//   所以 widget test 推進假時間就能驗證回到靜止。
// - ambient 在 TickerMode 關閉（被別的路由蓋住）時暫停；系統要求減少動態時只顯示基準姿勢。
// - 背景與會動的部件分成兩層：背景放在自己的 RepaintBoundary，部件用一次 drawRawAtlas 畫完。
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 場景裡一個會動的部件：錄好的像素（座標單位是格）與它佔的格子範圍。
class PixelPart {
  const PixelPart(this.picture, this.bounds);
  final ui.Picture picture;
  final Rect bounds;
}

/// 一個像素場景：不會動的背景、會動部件拼成的 atlas，以及場景的格數與每格邏輯點。
class PixelScene {
  PixelScene._({
    required this.widthCells,
    required this.heightCells,
    required this.cell,
    required this.backImage,
    required this.atlasImage,
    required this.atlasRects,
    required this.partBounds,
  });

  final int widthCells;
  final int heightCells;

  /// 每一格畫成幾個邏輯點，取整數，乘上整數裝置像素比後每格對齊整數像素。
  final double cell;
  final ui.Image backImage; // 1 格 = 1 px
  final ui.Image atlasImage; // 1 格 = 1 px
  final Float32List atlasRects; // 每個部件四個值：left, top, right, bottom（atlas 座標）
  final List<Rect> partBounds; // 每個部件在場景裡的範圍（格）

  int get partCount => partBounds.length;
  Size get size => Size(widthCells * cell, heightCells * cell);

  /// 把背景與部件畫成點陣圖並拼成 atlas。部件之間留 1 px，取樣時不會碰到相鄰部件的像素。
  /// [parts] 的順序就是繪製順序，後面的蓋在前面的上面。
  static PixelScene build({
    required int widthCells,
    required int heightCells,
    required double cell,
    required ui.Picture back,
    required List<PixelPart> parts,
  }) {
    const maxWidth = 256, gap = 1;
    final rects = Float32List(parts.length * 4);
    var x = gap, y = gap, rowHeight = 0, usedWidth = gap;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    for (var i = 0; i < parts.length; i++) {
      final b = parts[i].bounds;
      final w = b.width.toInt(), h = b.height.toInt();
      if (x + w + gap > maxWidth) {
        x = gap;
        y += rowHeight + gap;
        rowHeight = 0;
      }
      canvas.save();
      canvas.translate(x - b.left, y - b.top);
      canvas.drawPicture(parts[i].picture);
      canvas.restore();
      rects.setAll(i * 4, [x.toDouble(), y.toDouble(), (x + w).toDouble(), (y + h).toDouble()]);
      x += w + gap;
      usedWidth = math.max(usedWidth, x);
      rowHeight = math.max(rowHeight, h);
    }
    return PixelScene._(
      widthCells: widthCells,
      heightCells: heightCells,
      cell: cell,
      backImage: back.toImageSync(widthCells, heightCells),
      atlasImage: rec.endRecording().toImageSync(usedWidth, y + rowHeight + gap),
      atlasRects: rects,
      partBounds: [for (final p in parts) p.bounds],
    );
  }
}

/// 一個姿勢：每個部件的位移（整數格），以及動作是否已經結束（ambient 不看這個值）。
class PixelPose {
  const PixelPose(this.offsets, {this.done = false});
  final List<Offset> offsets;
  final bool done;
}

/// 姿勢函數：輸入動作開始後的經過時間，輸出姿勢。
/// event 變體觸發的當下就以 elapsed = 一個姿勢間隔呼叫第一次，之後每個間隔呼叫一次。
typedef PixelMotionFn = PixelPose Function(Duration elapsed);

enum PixelMotionVariant { event, ambient }

/// 呼叫端從外部觸發 event 變體。
class PixelMotionController extends ChangeNotifier {
  void trigger() => notifyListeners();
}

/// PixelMotion 用到的 token。app 用 ThemeData.extensions 覆寫；沒給時用 [fallback]。
@immutable
class PixelMotionTheme extends ThemeExtension<PixelMotionTheme> {
  const PixelMotionTheme({
    this.poseInterval = const Duration(milliseconds: 100),
    this.hitTarget = const Size(24, 24),
    this.focusColor = const Color(0xFF4C9AFF),
  });

  /// motion.poseInterval
  final Duration poseInterval;

  /// hitTarget.desktop：WCAG 2.2 的 2.5.8 Target Size (Minimum)
  final Size hitTarget;

  /// color.focus
  final Color focusColor;

  static const PixelMotionTheme fallback = PixelMotionTheme();

  static PixelMotionTheme of(BuildContext context) =>
      Theme.of(context).extension<PixelMotionTheme>() ?? fallback;

  @override
  PixelMotionTheme copyWith({Duration? poseInterval, Size? hitTarget, Color? focusColor}) => PixelMotionTheme(
        poseInterval: poseInterval ?? this.poseInterval,
        hitTarget: hitTarget ?? this.hitTarget,
        focusColor: focusColor ?? this.focusColor,
      );

  @override
  PixelMotionTheme lerp(PixelMotionTheme? other, double t) => t < 0.5 || other == null ? this : other;
}

class PixelMotion extends StatefulWidget {
  const PixelMotion({
    super.key,
    required this.variant,
    required this.scene,
    required this.motion,
    this.controller,
    this.semanticLabel,
  }) : assert(variant == PixelMotionVariant.ambient || semanticLabel != null,
            'event 變體可以聚焦與觸發，要給輔助技術朗讀的名稱');

  final PixelMotionVariant variant;
  final PixelScene scene;
  final PixelMotionFn motion;
  final PixelMotionController? controller;
  final String? semanticLabel;

  @override
  State<PixelMotion> createState() => PixelMotionState();
}

class PixelMotionState extends State<PixelMotion> {
  late final ValueNotifier<List<Offset>> pose = ValueNotifier(_rest);
  Timer? _timer;
  int _ticks = 0;
  bool _focused = false;
  bool _tickerEnabled = true;
  bool _reduced = false;
  Duration _interval = PixelMotionTheme.fallback.poseInterval;

  List<Offset> get _rest => List.filled(widget.scene.partCount, Offset.zero);

  /// 目前有沒有計時器在跑。測試用來驗證靜止與暫停時沒有計時器。
  @visibleForTesting
  bool get isRunning => _timer != null;

  /// 目前有沒有鍵盤焦點（焦點環是否顯示）。
  @visibleForTesting
  bool get isFocused => _focused;

  bool get _event => widget.variant == PixelMotionVariant.event;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(trigger);
  }

  @override
  void didUpdateWidget(PixelMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(trigger);
      widget.controller?.addListener(trigger);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interval = PixelMotionTheme.of(context).poseInterval;
    final ticker = TickerMode.valuesOf(context).enabled;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final changed = interval != _interval || ticker != _tickerEnabled || reduced != _reduced;
    _interval = interval;
    _tickerEnabled = ticker;
    _reduced = reduced;
    if (reduced) {
      _stop();
      pose.value = _rest;
    } else if (!_event) {
      if (!ticker) {
        _stop(); // paused：停在最後一個姿勢
      } else if (_timer == null || changed) {
        _startAmbient();
      }
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _apply(PixelPose p) {
    final next = p.offsets;
    final cur = pose.value;
    var same = next.length == cur.length;
    for (var i = 0; same && i < next.length; i++) {
      same = next[i] == cur[i];
    }
    if (!same) pose.value = List.of(next);
  }

  void _startAmbient() {
    _stop();
    _timer = Timer.periodic(_interval, (_) {
      _ticks++;
      _apply(widget.motion(_interval * _ticks));
    });
  }

  /// event 變體：從頭開始一段動作。ambient 或減少動態時沒有作用。
  void trigger() {
    if (!_event || _reduced || !mounted) return;
    _stop();
    _ticks = 1;
    if (_step()) return;
    _timer = Timer.periodic(_interval, (_) {
      _ticks++;
      _step();
    });
  }

  /// 套用目前這一格的姿勢；動作結束時回到基準姿勢、取消計時器，回傳 true。
  bool _step() {
    final p = widget.motion(_interval * _ticks);
    if (p.done) {
      _stop();
      _apply(PixelPose(_rest));
      return true;
    }
    _apply(p);
    return false;
  }

  @override
  void dispose() {
    widget.controller?.removeListener(trigger);
    _stop();
    pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = PixelMotionTheme.of(context);
    final scene = widget.scene;
    Widget layers = RepaintBoundary(
      child: Stack(
        alignment: Alignment.topLeft, // 不帶方向，祖先不必提供 Directionality
        children: [
          RepaintBoundary(child: CustomPaint(size: scene.size, painter: _BackPainter(scene))),
          CustomPaint(size: scene.size, painter: _PartsPainter(scene, pose)),
        ],
      ),
    );
    layers = ConstrainedBox(
      constraints: BoxConstraints(minWidth: theme.hitTarget.width, minHeight: theme.hitTarget.height),
      child: Center(widthFactor: 1, heightFactor: 1, child: layers),
    );

    // 朗讀標籤需要文字方向；祖先沒有 Directionality 時以由左到右處理，元件不依賴祖先提供。
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;

    if (!_event) {
      final label = widget.semanticLabel;
      return label == null
          ? ExcludeSemantics(child: layers)
          : Semantics(image: true, label: label, textDirection: textDirection, child: layers);
    }

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      textDirection: textDirection,
      onTap: trigger,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => trigger())},
        onFocusChange: (f) => setState(() => _focused = f),
        child: GestureDetector(
          onTap: trigger,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: _focused ? Border.all(color: theme.focusColor, width: 2) : null,
            ),
            child: layers,
          ),
        ),
      ),
    );
  }
}

/// 放大時用最近鄰取樣，一格放大成 cell × cell 個邏輯點、邊緣不糊。
final Paint _pixelPaint = Paint()..filterQuality = FilterQuality.none;

/// 把場景的背景與某個姿勢的部件畫到 [canvas] 上（座標單位是邏輯點）。
/// 元件的兩層 painter 用的就是這兩個函數；測試拿它跟逐部件重播 Picture 的畫法比對。
void paintPixelBack(Canvas canvas, PixelScene scene) {
  canvas.save();
  canvas.scale(scene.cell);
  canvas.drawImage(scene.backImage, Offset.zero, _pixelPaint);
  canvas.restore();
}

void paintPixelParts(Canvas canvas, PixelScene scene, List<Offset> offsets, [Float32List? transforms]) {
  final t = transforms ?? Float32List(scene.partCount * 4);
  for (var i = 0; i < scene.partCount; i++) {
    final b = scene.partBounds[i];
    t
      ..[i * 4] = 1
      ..[i * 4 + 1] = 0
      ..[i * 4 + 2] = b.left + offsets[i].dx
      ..[i * 4 + 3] = b.top + offsets[i].dy;
  }
  canvas.save();
  canvas.scale(scene.cell);
  canvas.drawRawAtlas(scene.atlasImage, t, scene.atlasRects, null, null, null, _pixelPaint);
  canvas.restore();
}

class _BackPainter extends CustomPainter {
  _BackPainter(this.scene);
  final PixelScene scene;

  @override
  void paint(Canvas canvas, Size size) => paintPixelBack(canvas, scene);

  @override
  bool shouldRepaint(_BackPainter old) => old.scene != scene;
}

class _PartsPainter extends CustomPainter {
  _PartsPainter(this.scene, this.pose)
      : transforms = Float32List(scene.partCount * 4),
        super(repaint: pose);
  final PixelScene scene;
  final ValueListenable<List<Offset>> pose;
  final Float32List transforms;

  @override
  void paint(Canvas canvas, Size size) => paintPixelParts(canvas, scene, pose.value, transforms);

  @override
  bool shouldRepaint(_PartsPainter old) => old.scene != scene || old.pose != pose;
}
