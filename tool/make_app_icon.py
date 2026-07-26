"""元絵(assets/icon/source-koko-meshi-icon.png)からアプリアイコン素材を作る。

    python tool/make_app_icon.py                 素材を書き出す
    python tool/make_app_icon.py --preview       背景色の候補を比較する
    python tool/make_app_icon.py --preview-scale 前景の倍率の候補を比較する

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

# 背景色。同じ作者の OmniVerse がホーム画面で見せている薄紫にそろえる。
# アプリ内のデザインシステム(和の食記録帳)には無い色だが、アイコンは
# ホーム画面で他のアプリと並ぶもので、絵柄ごと1つの作品として扱う
BACKGROUND = (0xCA, 0xBC, 0xD6)

# Adaptive Icon は 108dp のうち中央 72dp(66%)しか表示保証がない。
# ただし元絵は角の丸いカメラなので、正方形の保証枠より少しはみ出せる。
# 0.84 まで上げると円マスクでカメラの左右が切れる(--preview-scale で確認)
FOREGROUND_SCALE = 0.78
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


def sheet(composed_list, path):
    """候補を、円マスク(上段)と角丸マスク(下段)で並べて書き出す。

    ランチャーのマスクは端末や設定で変わる。最も削られる円で切れないかを
    見るための確認用。
    """
    cell = MASTER // 2
    out_sheet = Image.new("RGB", (cell * len(composed_list), cell * 2), (40, 40, 40))
    for i, composed in enumerate(composed_list):
        for j, shape in enumerate(("circle", "squircle")):
            mask = Image.new("L", (MASTER, MASTER), 0)
            d = ImageDraw.Draw(mask)
            if shape == "circle":
                d.ellipse((0, 0, MASTER - 1, MASTER - 1), fill=255)
            else:
                d.rounded_rectangle((0, 0, MASTER - 1, MASTER - 1), radius=230, fill=255)
            out = Image.new("RGB", (MASTER, MASTER), (40, 40, 40))
            out.paste(composed, (0, 0), mask)
            out_sheet.paste(out.resize((cell, cell), Image.LANCZOS), (i * cell, j * cell))
    out_sheet.save(path)
    print(f"wrote {path}")


def preview_background(art):
    """背景色の候補を並べる。"""
    candidates = [
        ("薄紫", (0xCA, 0xBC, 0xD6)),
        ("漆", (0xB0, 0x49, 0x2A)),
        ("生成り", (0xF7, 0xF2, 0xEA)),
        ("夜", (0x17, 0x13, 0x0E)),
        ("抹茶", (0x69, 0x79, 0x3F)),
    ]
    sheet(
        [place(art, FOREGROUND_SCALE, bg + (255,)).convert("RGB") for _, bg in candidates],
        ICON_DIR / "preview-background.png",
    )
    print("左から:", " / ".join(name for name, _ in candidates))


def preview_scale(art):
    """前景の倍率の候補を並べる。円マスクで切れ始める境目を見る。"""
    scales = [0.70, 0.78, 0.84, 0.90]
    sheet(
        [place(art, s, BACKGROUND + (255,)).convert("RGB") for s in scales],
        ICON_DIR / "preview-scale.png",
    )
    print("左から:", " / ".join(str(s) for s in scales))


def main():
    art = load_art()
    print("content size:", art.size)

    if "--preview" in sys.argv:
        preview_background(art)
        return
    if "--preview-scale" in sys.argv:
        preview_scale(art)
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
