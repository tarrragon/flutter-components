# flutter_components

多個 Flutter app 共用的元件庫。每個元件都有一份契約，寫明語意、變體、狀態、尺寸、內容政策、slot、組合規則、無障礙、回饋與測試；頁面只從這裡選用元件，不自己拼排列與動畫。

## 元件

| 元件 | 用途 | 契約 |
|------|------|------|
| `PixelMotion` | 讓逐格像素圖的部件依事件（`event`）或固定節奏（`ambient`）換整數格姿勢；姿勢不變時不重畫，靜止時不讓畫面排下一幀 | 元件庫規格 4.1 |

目前只支援桌機（指標加鍵盤）。

```dart
final scene = PixelScene.build(
  widthCells: 16, heightCells: 10, cell: 4, // 場景格數與每格邏輯點
  back: backPicture,                        // 不會動的背景，座標單位是格
  parts: [PixelPart(partPicture, partBounds)],
);

PixelMotion(
  variant: PixelMotionVariant.event,
  scene: scene,
  motion: (elapsed) => PixelPose([...], done: elapsed > total), // 每個部件的整數格位移
  semanticLabel: '按下起一陣風',                               // event 必填，從 i18n 取值
);
```

token 用 `ThemeData.extensions` 覆寫：`PixelMotionTheme(poseInterval:, hitTarget:, focusColor:)`。

## 引用方式

在 app 的 `pubspec.yaml` 用 git 相依，`ref` 指定一個版本 tag：

```yaml
dependencies:
  flutter_components:
    git:
      url: https://github.com/tarrragon/flutter-components.git
      ref: <版本 tag>
```

元件的顏色、間距等 design token 由 app 經由 theme 提供，元件本身不寫死這些值。

## 開發

```bash
flutter analyze
flutter test
```
