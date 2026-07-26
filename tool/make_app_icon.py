"""元絵(assets/icon/source-koko-meshi-icon.png)からアプリアイコン素材を作る。

    python tool/make_app_icon.py            素材を書き出す
    python tool/make_app_icon.py --preview  背景色の候補を比較する

書き出したあと `dart run flutter_launcher_icons` で mipmap 一式を再生成する。

元絵は背景が透過のステッカー画像。背景色をここで決めて焼き込むので、
色を変えたいときは BACKGROUND と pubspec.yaml の adaptive_icon_background /
background_color_ios の3か所を揃えて変更する。

必要: Pillow (pip install Pillow)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "assets" / "icon"
SRC = ICON_DIR / "source-koko-meshi-icon.png"

MASTER = 1024

# 背景色。元絵の背景つきバージョンと同じ薄紫。
# アプリ内のデザインシステム(和の食記録帳)には無い色だが、アイコンは
# ホーム画面で他のアプリと並ぶもので、絵柄ごと1つの作品として扱う
BACKGROUND = (0xD4, 0xC6, 0xF7)

# Adaptive Icon は 108dp のうち中央 72dp(66%)しか表示保証がない。
# 円マスクでも切れず、かつ小さく見えすぎない大きさ(実機で確認して決定)
FOREGROUND_SCALE = 0.70
# 通常アイコンはマスクで削られないぶん少し大きくできる
ICON_SCALE = FOREGROUND_SCALE + 0.06


def load_art():
    """元絵を余白なしに切り詰めて返す。"""
    art = Image.open(SRC).convert("RGBA")
    box = art.getchannel("A").getbbox()
    if box is None:
        raise SystemExit(f"{SRC} に不透明な領域がありません")
    return art.crop(box)


def place(image, scale, background=None):
    """正方形キャンバスの中央へ、縦横比を保って scale の割合で載せる。"""
    canvas = Image.new("RGBA", (MASTER, MASTER), background or (0, 0, 0, 0))
    target = MASTER * scale
    r = min(target / image.width, target / image.height)
    fitted = image.resize(
        (round(image.width * r), round(image.height * r)), Image.LANCZOS
    )
    canvas.paste(
        fitted, ((MASTER - fitted.width) // 2, (MASTER - fitted.height) // 2), fitted
    )
    return canvas


def preview(art):
    """背景色の候補を、円マスク(上段)と角丸マスク(下段)で並べる。"""
    candidates = [
        ("薄紫", (0xD4, 0xC6, 0xF7)),
        ("漆", (0xB0, 0x49, 0x2A)),
        ("生成り", (0xF7, 0xF2, 0xEA)),
        ("夜", (0x17, 0x13, 0x0E)),
        ("抹茶", (0x69, 0x79, 0x3F)),
    ]
    cell = MASTER // 2
    sheet = Image.new("RGB", (cell * len(candidates), cell * 2), (128, 128, 128))
    for i, (_, bg) in enumerate(candidates):
        composed = place(art, FOREGROUND_SCALE, bg + (255,)).convert("RGB")
        for j, shape in enumerate(("circle", "squircle")):
            mask = Image.new("L", (MASTER, MASTER), 0)
            d = ImageDraw.Draw(mask)
            if shape == "circle":
                d.ellipse((0, 0, MASTER - 1, MASTER - 1), fill=255)
            else:
                d.rounded_rectangle((0, 0, MASTER - 1, MASTER - 1), radius=230, fill=255)
            out = Image.new("RGB", (MASTER, MASTER), (128, 128, 128))
            out.paste(composed, (0, 0), mask)
            sheet.paste(out.resize((cell, cell), Image.LANCZOS), (i * cell, j * cell))
    path = ICON_DIR / "preview-background.png"
    sheet.save(path)
    print(f"wrote {path}")
    print("左から:", " / ".join(name for name, _ in candidates))


def main():
    art = load_art()
    print("content size:", art.size)

    if "--preview" in sys.argv:
        preview(art)
        return

    # 通常アイコン: iOSはアルファ不可なので不透明で書き出す
    place(art, ICON_SCALE, BACKGROUND + (255,)).convert("RGB").save(
        ICON_DIR / "app_icon.png"
    )
    # Adaptive 前景: 背景色は pubspec.yaml の adaptive_icon_background で指定
    place(art, FOREGROUND_SCALE).save(ICON_DIR / "app_icon_foreground.png")
    print("background:", "#%02X%02X%02X" % BACKGROUND)
    print("wrote app_icon.png / app_icon_foreground.png")
    print("次: dart run flutter_launcher_icons")


if __name__ == "__main__":
    main()
