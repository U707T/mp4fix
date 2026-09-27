#!/usr/bin/env python3
"""从 `tool/icon_source.png` 生成整套应用图标（Android 传统 + 自适应 + Windows .ico）。

素材：一张 1060×1060 的方形图（已裁掉水印），主体（层叠的视频卡片 + 播放键 + 裂纹波形）
约占画面 88%，背景是浅蓝渐变。

产物：
  android/app/src/main/res/mipmap-*/ic_launcher.png           传统图标（圆角）
  android/app/src/main/res/mipmap-*/ic_launcher_background.png 自适应背景（主体缩进安全区）
  android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml   自适应图标描述
  windows/runner/resources/app_icon.ico                        Windows 多尺寸图标
  tool/icon_preview.png                                        预览（人工确认用）

用法：
    python3 tool/generate_app_icons.py
"""

import os

from PIL import Image, ImageDraw, ImageFilter

# 素材里主体（视频卡片）所占比例 —— 用于把主体收进自适应图标的安全区（约 66%）
MOTIF_RATIO_IN_SOURCE = 0.88
ADAPTIVE_SAFE_ZONE = 0.66

LEGACY_SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE_SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def load_source(root):
    path = os.path.join(root, "tool", "icon_source.png")
    if not os.path.exists(path):
        raise SystemExit(f"缺少素材：{path}")
    return Image.open(path).convert("RGB")


def rounded(img, radius_ratio=0.22):
    """把方形图裁成圆角方块（带透明边角）。"""
    size = img.size[0]
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img.convert("RGBA"), (0, 0))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=255
    )
    out.putalpha(mask)
    return out


def mirror_pad(img, target):
    """把 [img] 居中放进 [target]×[target]，四周用镜像延展（背景是渐变，接缝几乎不可见）。"""
    w, h = img.size
    pad = int((target - w) / 2)
    out = Image.new("RGB", (target, target))

    def paste(part, box, op=None):
        if op is not None:
            part = part.transpose(op)
        out.paste(part, box)

    paste(img, (pad, pad))
    # 四条边
    paste(img.crop((0, 0, pad, h)), (0, pad), Image.FLIP_LEFT_RIGHT)
    paste(img.crop((w - pad, 0, w, h)), (pad + w, pad), Image.FLIP_LEFT_RIGHT)
    paste(img.crop((0, 0, w, pad)), (pad, 0), Image.FLIP_TOP_BOTTOM)
    paste(img.crop((0, h - pad, w, h)), (pad, pad + h), Image.FLIP_TOP_BOTTOM)
    # 四个角（对镜像块再镜像）
    paste(img.crop((0, 0, pad, pad)), (0, 0), Image.ROTATE_180)
    paste(img.crop((w - pad, 0, w, pad)), (pad + w, 0), Image.ROTATE_180)
    paste(img.crop((0, h - pad, pad, h)), (0, pad + h), Image.ROTATE_180)
    paste(img.crop((w - pad, h - pad, w, h)), (pad + w, pad + h), Image.ROTATE_180)

    # 只对"外圈"做一次柔化，让镜像接缝彻底看不出来（中心主体保持锐利）
    blurred = out.filter(ImageFilter.GaussianBlur(radius=max(2, pad * 0.35)))
    mask = Image.new("L", (target, target), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [pad, pad, pad + w, pad + h], radius=int(min(w, h) * 0.12), fill=255
    )
    mask = mask.filter(ImageFilter.GaussianBlur(radius=max(2, pad * 0.5)))
    return Image.composite(out, blurred, mask)


def legacy_icon(source, size):
    return rounded(source.resize((size, size), Image.LANCZOS))


def adaptive_background(source, size):
    """自适应背景层：主体缩进安全区，四周由镜像 + 柔化的同色背景补足。"""
    w = source.size[0]
    motif = w * MOTIF_RATIO_IN_SOURCE
    canvas = int(motif / ADAPTIVE_SAFE_ZONE)
    padded = mirror_pad(source, canvas)
    return padded.resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source = load_source(root)
    res = os.path.join(root, "android", "app", "src", "main", "res")

    for name, px in LEGACY_SIZES.items():
        save(legacy_icon(source, px), os.path.join(res, f"mipmap-{name}", "ic_launcher.png"))
        save(
            adaptive_background(source, ADAPTIVE_SIZES[name]),
            os.path.join(res, f"mipmap-{name}", "ic_launcher_background.png"),
        )
        print(f"android mipmap-{name}: legacy {px}px / adaptive {ADAPTIVE_SIZES[name]}px")

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
            "</adaptive-icon>\n"
        )

    # 主题图标（Android 13+）没有单色素材，这里不声明 monochrome 层

    # Windows 图标
    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    ico = os.path.join(root, "windows", "runner", "resources", "app_icon.ico")
    os.makedirs(os.path.dirname(ico), exist_ok=True)
    legacy_icon(source, 256).save(ico, format="ICO", sizes=ico_sizes)
    print("windows app_icon.ico")

    # 预览：传统图标各尺寸 + 自适应合成示意（圆形裁切）
    sheet = Image.new("RGBA", (860, 260), (245, 245, 248, 255))
    x = 24
    for px in (48, 72, 96, 144, 192, 256):
        sheet.paste(legacy_icon(source, px), (x, 130 - px // 2), legacy_icon(source, px))
        x += px + 16
    # 圆形裁切的自适应示意
    for px in (128, 192):
        bg = adaptive_background(source, px)
        mask = Image.new("L", (px, px), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, px - 1, px - 1], fill=255)
        circle = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        circle.paste(bg.convert("RGBA"), (0, 0), mask)
        sheet.paste(circle, (x, 130 - px // 2), circle)
        x += px + 16
    preview = os.path.join(root, "tool", "icon_preview.png")
    sheet.save(preview)
    print("preview:", preview)


if __name__ == "__main__":
    main()
