# Hax Shot 图标资源

`assets/icons/hax_shot.svg` 是本项目原创的应用图标源文件；同目录下的 Linux PNG 由它生成，按 hicolor 目录规范提供 16–512 像素尺寸。

生成示例：

```bash
for size in 16 24 32 48 64 128 256 512; do
  magick -background none assets/icons/hax_shot.svg \
    -resize "${size}x${size}" -depth 8 \
    "linux/icons/hicolor/${size}x${size}/apps/com.github.xiehanff.hax_shot.png"
done
```
