"""同梱フォント(BIZ UDGothic)を Google Fonts から取得して assets/fonts/ に置く。

    python tool/fetch_fonts.py

フォントは SIL Open Font License 1.1。再配布にあたり OFL.txt も一緒に取得し、
アプリのライセンス画面に出す(lib/main.dart の _registerFontLicenses)。

--- 書体を選び直したくなったら ---

BIZ UDGothic を採用したのは、価格・カロリーの桁が揃うため。数字の字幅が
均一(1024)で、等幅数字(tnum)を持たない書体でも桁がずれない。
プロポーショナル版の BIZ UDPGothic は字幅が2種類に割れていて不可。

比較した他の候補と、そのときに分かったこと:
  - Zen Kaku Gothic New (ofl/zenkakugothicnew) … 静的ウェイトあり。
    数字の字幅が9種類に割れる(実害は小さいが揃わない)
  - M PLUS 2 (ofl/mplus2) … 可変フォントのみ。tnum あり
  - Noto Sans JP (ofl/notosansjp) … 可変フォントのみ。数字の字幅は均一

可変フォントしか無いファミリは、Flutter が `wght` 軸を `fontWeight` から
自動では動かさない(明示的に fontVariations を書く必要がある)ため、
fontTools で静的インスタンスに落としてから使うこと:

    from fontTools.varLib import instancer
    instancer.instantiateVariableFont(font, {"wght": 400}, inplace=True)
"""

import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "assets" / "fonts"
RAW = "https://raw.githubusercontent.com/google/fonts/main/ofl"

FAMILY_DIR = "bizudgothic"
FAMILY = "BIZUDGothic"
WEIGHTS = {400: "BIZUDGothic-Regular.ttf", 700: "BIZUDGothic-Bold.ttf"}


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "koko-meshi-font-fetch"})
    with urllib.request.urlopen(req) as r:
        return r.read()


def main():
    out_dir = DEST / FAMILY
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "OFL.txt").write_bytes(fetch(f"{RAW}/{FAMILY_DIR}/OFL.txt"))

    total = 0
    for weight, src_name in WEIGHTS.items():
        out = out_dir / f"{FAMILY}-{weight}.ttf"
        out.write_bytes(fetch(f"{RAW}/{FAMILY_DIR}/{src_name}"))
        total += out.stat().st_size
        print(f"  {out.relative_to(ROOT)}  {out.stat().st_size/1024/1024:.1f} MB")

    print(f"\n合計 {total/1024/1024:.1f} MB")


if __name__ == "__main__":
    main()
