# MVP2：自启动与基础标注

MVP2 在原有“冻结截图 → 框选 → 保存/复制”流程上增加三个能力：登录自启动、矩形标注和箭头标注。

## 1. 开机自启动

Hax Shot 不使用 root 权限，也不修改系统级服务。设置页的“开机自启动”开关会在当前用户目录创建或删除：

```text
~/.config/autostart/com.github.xiehanff.hax_shot.desktop
```

其中 `Exec` 使用当前实际运行的 tray 宿主路径：

- 源码运行时指向当前 Flutter bundle；
- RPM 安装后指向 `/usr/bin/hax_shot`。

自启动只启动普通托盘宿主，不会直接进入 `--capture` 模式。这样登录后只出现一个托盘图标，用户仍通过 `Alt+Z` 或托盘菜单开始截图。

## 2. 标注的交互边界

一次截图包含两个不同的矩形：

1. **截图选区**：第一次拖拽决定最终要保存/复制的图片范围；
2. **标注范围**：点击矩形或箭头工具后，在截图选区内部再次拖拽。

第二次拖拽不会改变截图选区，只会新增标注。标注起点和终点会被限制在截图选区内。

### 矩形

1. 第一次拖拽完成截图选区；
2. 点击工具条的矩形图标；
3. 选择红、紫、黄、绿或橙色；
4. 在截图选区内拖拽；
5. 松开鼠标后提交一个对应颜色的矩形。

矩形使用拖拽起点和终点构造 `Rect.fromPoints`，因此向任意方向拖动都有效。

### 箭头

1. 第一次拖拽完成截图选区；
2. 点击工具条的箭头图标；
3. 选择颜色；
4. 在截图选区内按下并拖动；
5. 松开鼠标后提交箭头。

箭头保留拖拽方向：起点是箭尾，终点是箭头尖端；拖动距离决定箭头长度。箭头由一条线段和两条开放式箭头翼组成。

## 3. 坐标和导出

`ScreenshotAnnotation` 暂存为 Flutter overlay 的逻辑像素坐标，使用左上角为原点、向下为正的坐标系。绘制时直接叠加在冻结画面上。

保存或复制时，`CapturePage._renderSelection()` 将同一组标注转换到裁剪图片的像素坐标：

```text
overlay logical point
  → 减去裁剪区域在 overlay 中的起点
  → 除以 ScreenshotLayout.scale
  → 绘制到裁剪后的 PNG
```

预览和最终 PNG 共用 `paintScreenshotAnnotation()` 的矩形/箭头几何规则，避免预览和导出形状不一致。

## 4. 代码入口

| 文件 | 职责 |
|---|---|
| `lib/features/settings/autostart_service.dart` | 管理当前用户 XDG autostart desktop 文件 |
| `lib/features/settings/shortcut_settings_page.dart` | 快捷键和自启动开关 |
| `lib/features/capture/annotation.dart` | 工具类型、标注模型和颜色板 |
| `lib/features/capture/capture_page.dart` | 工具切换、标注拖拽、保存/复制前的像素坐标转换 |
| `lib/features/capture/screenshot_canvas.dart` | 预览绘制和统一标注几何 |
| `lib/features/capture/capture_toolbar.dart` | 矩形/箭头工具、颜色和输出操作 |

## 5. 当前边界

MVP2 暂时只支持矩形和箭头，不支持选中后移动、缩放、删除单个标注、文字、马赛克和撤销。按下矩形或箭头工具后可以连续绘制多个标注；点击“框选截图区域”可以重新选择截图范围并清空旧标注。

一句话总结：**第一次拖拽决定图片，后续拖拽绘制标注，保存和复制都使用同一份带标注的 PNG。**
