#!/usr/bin/env python3
"""
界面结构门禁（判读侧）：读设置页截图，检查卡片有没有「被拆散」。

用法: analyze.py <dark.png> <light.png> ...

判据
----
一张卡片被打散时，行与行之间会露出约 4pt 高的面板底色横缝；正常页面里，
上下两张卡片之间至少隔着「区块间距 24pt +（或）区块标题 28pt」，实测 23–57pt。

工作方式：定出两种底色（面板底色取页面顶部留白；卡片底色逐行取「该行占比最大的颜色」，
再看哪个非面板色当过足够多行的主角），按「该行是否以卡片底色为主」切出卡片段，
量相邻段之间的间隙 —— 短于 15pt 的即被打散的横缝。

两个必要的补丁，都是实测逼出来的：

1. **闭运算填掉细碎噪声**。Divider（0.5pt）与文字密集行会让卡片内部的个别行
   「卡片底色占比 < 50%」，把一张卡片切成好几段、量出 0–2pt 的假间隙。
   所以先把长度 < `FILL_MAX_PT` 的非卡片段填成卡片。这个阈值**必须严格小于拆散缝宽**
   —— 实测噪声最长 1.5pt、拆散缝 4.0pt，取 2.5pt。曾误取 4.0pt（＝缺陷本身），
   结果修复前的版本也被填成"通过"，反向验证才暴露出来。

2. **浅色主题不适用颜色判据**。浅色下 `cardBackground`（controlBackgroundColor）与
   `panelBackground`（windowBackgroundColor）**在本机都解析成纯白 (255,255,255)**，
   卡片只靠 0.5pt 描边区分。识别卡片底色的方式因此必须是「逐行找出该行占比最大的颜色，
   再看哪个非面板色当过足够多行的主角」；不能取「全图出现最多的非面板色」——
   那样会抓到文字色 (39,39,39)，绕过可区分性判断，最后误报成「整页只有一种底色」。
   判定不可区分时不做拆散判定，只报「渲染非空白 + 整页高度」，拆散与否改由
   「两套主题高度必须一致」兜住（同一份布局，高度必须相同）。

走过的弯路（别再踩）
--------------------
Swift 侧读像素四条路都不通：`NSBitmapImageRep.colorAt` 返回 nil；
`bitmapImageRepForCachingDisplay` 的 `bitmapData` 全 0；它的 `cgImage` 画进 CGContext
也是全 0；`NSBitmapImageRep(data: png)` 懒解压、`bitmapData` 同样全 0。
而同一份 rep 导出的 PNG 内容完全正常 —— 所以走 PNG → 未压缩 BMP 再按字节读。

判据本身也不能只看「某一条竖线上有没有缝」：页面外边距 16pt、行内 padding 14pt，
竖线要么落在留白里（整列都是面板色，判据零值假通过），要么穿过左侧的图标。
"""
import array
import struct
import subprocess
import sys
from collections import Counter

ROW_STEP = 4          # 横向采样步长（物理像素）
COLOR_TOL = 2         # 颜色相等容差：面板底色与卡片底色只差约 7/255，容差必须小于它
CARD_ROW_RATIO = 0.5  # 一行里 >50% 是卡片底色 → 判为卡片行（容忍文字与图标）
FILL_MAX_PT = 2.5     # 长度短于此值的非卡片段填成卡片（抹掉 Divider / 文字行噪声）
                      # ⚠️ 必须严格小于「被拆散」的缝宽，否则会把要检的缺陷当噪声填掉。
                      # 实测：噪声（Divider 0.5pt、文字密集行、圆角抗锯齿）最长 1.5pt，
                      # 拆散缝是 4.0pt —— 取中间的 2.5pt。（曾误用 4.0pt，于是修复前的
                      # 版本也能"通过"，门禁形同虚设。）
MIN_GAP_PT = 15.0     # 相邻卡片段的间隙短于此值 → 判为「卡片被拆散」
                      # （实测正常间隙 24pt 与 57pt，拆散缝 4pt）
MIN_CARD_ROWS = 0.10  # 卡片底色至少要当上这么多比例的行主色，才算「真的是一种背景色」


def to_bmp(png_path):
    bmp_path = png_path[:-4] + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png_path, "--out", bmp_path],
                   check=True, capture_output=True)
    return bmp_path


def read_bmp(path):
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        raise SystemExit(f"{path}: 不是 BMP")
    off = struct.unpack("<I", d[10:14])[0]
    w = struct.unpack("<i", d[18:22])[0]
    h = abs(struct.unpack("<i", d[22:26])[0])
    bpp = struct.unpack("<H", d[28:30])[0]
    if bpp != 32:
        raise SystemExit(f"{path}: 预期 32 位 BMP，实际 {bpp} 位")
    rmask, gmask, bmask, _ = struct.unpack("<IIII", d[54:70])

    def shift(mask):
        return (mask & -mask).bit_length() - 1 if mask else 0

    px = array.array("I")
    px.frombytes(d[off:off + w * h * 4])
    return w, h, px, shift(rmask), shift(gmask), shift(bmask)


def main():
    paths = sys.argv[1:]
    if not paths:
        print("用法: analyze.py <png> [更多 png]")
        return 2

    failed = 0
    heights = {}
    for png in paths:
        label = png.rsplit("/", 1)[-1].replace("settings-", "").replace(".png", "")
        print(f"\n【{label} 主题】")
        w, h, px, rs, gs, bs = read_bmp(to_bmp(png))
        scale = w / 400.0  # 物理像素 → pt
        heights[label] = h / scale

        def rgb(x, y):
            p = px[y * w + x]
            return ((p >> rs) & 0xFF, (p >> gs) & 0xFF, (p >> bs) & 0xFF)

        def near(c, target):
            return (abs(c[0] - target[0]) <= COLOR_TOL
                    and abs(c[1] - target[1]) <= COLOR_TOL
                    and abs(c[2] - target[2]) <= COLOR_TOL)

        # 面板底色：页面顶部留白那一行（y=4pt）。页面外圈一定是面板底色，
        # 这一步不需要知道卡片长什么样。
        panel = Counter(rgb(x, int(4 * scale)) for x in range(0, w, ROW_STEP)).most_common(1)[0][0]

        # 卡片底色：逐行找出「该行占比最大的颜色」，再看哪些非面板色当过足够多行的主角。
        # 卡片底色必须是能占满整行的背景色。这一条不能省 —— 若把「全图出现最多的
        # 非面板色」直接当卡片底，浅色主题下会抓到文字色 (39,39,39)（实测），
        # 于是「两种底色不可区分」的判断被绕过，最后以「整页只有一种底色」误报。
        row_boss = Counter()
        for y in range(h):
            row_boss[Counter(rgb(x, y) for x in range(0, w, ROW_STEP)).most_common(1)[0][0]] += 1
        candidates = [(c, n) for c, n in row_boss.items()
                      if not near(c, panel) and n / h >= MIN_CARD_ROWS]
        if not candidates:
            # 浅色主题即此情形：panelBackground 与 cardBackground 都是系统语义色，
            # 在本机解析成同一个纯白（实测都是 255,255,255），卡片只靠 0.5pt 描边区分，
            # 颜色判据无从下手。这时不做拆散判定，只报「渲染非空白 + 整页高度」，
            # 拆散与否改由「两套主题高度必须一致」兜住（同一份布局，高度必须相同）。
            other = [c for c, n in row_boss.most_common(4) if not near(c, panel)]
            print(f"  ✓ 渲染非空白（面板底色 {panel[0]},{panel[1]},{panel[2]}｜"
                  f"整页高 {h / scale:.0f}pt）")
            print(f"  ✓ 该主题下两种底色不可区分，颜色判据不适用"
                  f"（无占 ≥{MIN_CARD_ROWS:.0%} 行的非面板背景色"
                  + (f"；最接近的只是 {other[0]} 这类零散色" if other else "") + "）")
            continue
        card = max(candidates, key=lambda t: t[1])[0]

        def is_card_row(y):
            same = 0
            total = 0
            for x in range(0, w, ROW_STEP):
                if near(rgb(x, y), card):
                    same += 1
                total += 1
            return same / total > CARD_ROW_RATIO

        flags = [is_card_row(y) for y in range(h)]
        if all(flags) or not any(flags):
            print(f"  ✗ 整页只有一种底色（卡片行 {sum(flags)}/{h}）：渲染异常，无法判读")
            failed += 1
            continue

        # 闭运算：把过短的非卡片段填成卡片。Divider 只有 0.5pt，文字密集行会让个别行
        # 卡片底色占比跌破 50%，不填的话一张卡片会被切成好几段、量出成片的假间隙。
        fill_px = int(FILL_MAX_PT * scale)
        i = 0
        while i < h:
            if not flags[i]:
                start = i
                while i < h and not flags[i]:
                    i += 1
                if i - start <= fill_px:
                    for k in range(start, i):
                        flags[k] = True
            else:
                i += 1

        segs = []
        y = 0
        while y < h:
            if flags[y]:
                start = y
                while y < h and flags[y]:
                    y += 1
                segs.append((start, y))
            else:
                y += 1

        gaps = [(segs[i][1], segs[i + 1][0] - segs[i][1]) for i in range(len(segs) - 1)]
        bad = [(s, l) for s, l in gaps if l / scale < MIN_GAP_PT]

        print(f"  ✓ 渲染非空白（面板底色 {panel[0]},{panel[1]},{panel[2]}｜"
              f"卡片底色 {card[0]},{card[1]},{card[2]}｜整页高 {h / scale:.0f}pt）")
        print(f"  {'✗' if bad else '✓'} 卡片竖向连续，无「被拆散」的横缝"
              f"（识别出 {len(segs)} 张卡片，间隙 "
              + (", ".join(f"{l / scale:.0f}pt" for _, l in gaps) or "无") + "）")
        for s, l in bad[:6]:
            print(f"      y={s / scale:.0f}pt 处有 {l / scale:.1f}pt 的横缝"
                  f"（正常应 ≥{MIN_GAP_PT:.0f}pt）")
        if bad:
            failed += 1
            print(f"      截图: {png}")

    # 同一份布局在两套主题下渲染出的整页高度必须相等
    if len(heights) >= 2:
        values = list(heights.values())
        same = max(values) - min(values) < 1.0
        print(f"\n  {'✓' if same else '✗'} 两套主题整页高度一致"
              f"（" + ", ".join(f"{k}={v:.0f}pt" for k, v in heights.items()) + "）")
        if not same:
            failed += 1

    print("\n" + "─" * 50)
    print("全部通过" if failed == 0 else f"失败 {failed} 项")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
