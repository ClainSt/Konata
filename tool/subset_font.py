"""Konata v3 双维字体子集化与可变字重收缩构建脚本。"""

import argparse
import hashlib
from io import BytesIO
from pathlib import Path
import subprocess
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# 原始全量思源黑体可变字体（NotoSansCJKsc-VF.ttf）的权威校验摘要。
EXPECTED_SOURCE_SHA256 = (
    "990c807e79c25662a5a9ecf7f971baeb2bf2eab9a559e5ecf15cdfdb8561d21f"
)
SOURCE_REVISION = "f0276ca"
SOURCE_FONT = "apps/konata/assets/fonts/NotoSansCJKsc-VF.ttf"

# 额外保留的动漫标题、人名、长音及界面常用符号集合。
EXTRA_SYMBOLS = (
    "āīūēōĀĪŪĒŌáíúéóÁÍÚÉÓàìùèòÀÌÙÈÒâîûêôÂÎÛÊÔäïüëöÄÏÜËÖñÑçÇßœŒæÆ"
    "★☆♪♫♬♥♡·•—–…×÷±▾▸◂▴▲▼◀▶●○◆◇■□※℃℉№™©®§¶†‡‰′″←→↑↓↔↕⇒⇔"
    "∞≈≠≤≥√ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹⅺⅻ"
    "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳々〆〇ヶヵ"
    "凜凛凪澪緋櫻咲雫渚穹蒼蓮遙茜楓葵柚苺柊紬律梓唯"
    "喆镕淼犇玊吒啰啵哒咧嘛喔噢咦哟嗯哼唉嘿"
    "踏み躙られるだけの花エイティシックス"
)

# 水平排版保留的 OpenType 布局特性白名单（彻底剥离竖排、韩文组合及多区域重复变体特性）。
KEEP_LAYOUT_FEATURES = [
    "calt",
    "ccmp",
    "fwid",
    "halt",
    "hwid",
    "kern",
    "liga",
    "mark",
    "palt",
    "pwid",
    "tnum",
]

# 需要从裁剪产物中剥离的非必要表（竖排度量与数字签名）。
DROP_TABLES = [
    "DSIG",
    "vhea",
    "vmtx",
]


def _collect_gb2312() -> set[int]:
    """收集 GB2312 全量简体汉字与全角标点码位。"""
    codepoints: set[int] = set()
    for b1 in range(0xA1, 0xF8):
        for b2 in range(0xA1, 0xFF):
            try:
                ch = bytes([b1, b2]).decode("gb2312")
                if len(ch) == 1:
                    codepoints.add(ord(ch))
            except UnicodeDecodeError:
                continue
    return codepoints


def _collect_big5_common() -> set[int]:
    """收集 Big5 第一级常用繁体字与标点（约 5,400 字）。"""
    codepoints: set[int] = set()
    for b1 in range(0xA1, 0xC7):
        for b2 in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            if b1 == 0xC6 and b2 > 0x7E:
                continue
            try:
                ch = bytes([b1, b2]).decode("big5")
                if len(ch) == 1:
                    codepoints.add(ord(ch))
            except UnicodeDecodeError:
                continue
    return codepoints


def _collect_jis_x_0208() -> set[int]:
    """收集 JIS X 0208 第一与第二水准全部 6,355 个日文汉字及假名符号。"""
    codepoints: set[int] = set()
    for b1 in range(0xA1, 0xF5):
        for b2 in range(0xA1, 0xFF):
            try:
                ch = bytes([b1, b2]).decode("euc_jp")
                if len(ch) == 1:
                    codepoints.add(ord(ch))
            except UnicodeDecodeError:
                continue
    return codepoints


def read_source_blob(repo_root: Path, path: str) -> bytes:
    """从固定版本读取已移出当前工作树的原始字体和词表。"""
    return subprocess.check_output(
        ["git", "show", f"{SOURCE_REVISION}:{path}"], cwd=repo_root
    )


def _collect_repo_cjk_supplement(repo_root: Path) -> set[int]:
    """从固定版本的 OpenCC 词表提取基本区汉字，保证后续迁移词表时字集稳定。"""
    directory = "packages/engines/engine_playback/lib/src/domain/playback"
    tables = (
        "opencc_dictionaries.dart",
        "opencc_st_phrases_part1.dart",
        "opencc_st_phrases_part2.dart",
    )
    return {
        ord(ch)
        for name in tables
        for ch in read_source_blob(repo_root, f"{directory}/{name}").decode("utf-8")
        if 0x4E00 <= ord(ch) <= 0x9FFF
    }


def build_retention_unicodes(repo_root: Path) -> set[int]:
    """组装双维字体裁剪的完整保留码位集合。"""
    unicodes: set[int] = set()
    # 基础拉丁、拉丁补充及罗马音长音扩展区。
    unicodes.update(range(0x0020, 0x007F))
    unicodes.update(range(0x00A0, 0x0180))
    # 通用标点、中日韩标点符号与全角半角形式。
    unicodes.update(range(0x2000, 0x2070))
    unicodes.update(range(0x3000, 0x3040))
    unicodes.update(range(0xFF00, 0xFFF0))
    # 日文平假名、片假名与片假名语音扩展区。
    unicodes.update(range(0x3040, 0x30A0))
    unicodes.update(range(0x30A0, 0x3100))
    unicodes.update(range(0x31F0, 0x3200))
    # 简体、繁体与日文标准字符集。
    unicodes.update(_collect_gb2312())
    unicodes.update(_collect_big5_common())
    unicodes.update(_collect_jis_x_0208())
    unicodes.update(_collect_repo_cjk_supplement(repo_root))
    # 补充符号与重点番剧样例字符。
    for ch in EXTRA_SYMBOLS:
        unicodes.add(ord(ch))
    return unicodes


def sha256_file(path: Path) -> str:
    """计算目标文件的 SHA-256 十六进制摘要。"""
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def subset_variable_font(
    input_path: Path | None,
    output_path: Path,
    repo_root: Path,
) -> None:
    """执行字重轴收缩（400..700）与字符子集化并写出目标字体。"""
    source = input_path.read_bytes() if input_path else read_source_blob(repo_root, SOURCE_FONT)
    source_hash = hashlib.sha256(source).hexdigest()
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise ValueError(
            f"源字体 SHA-256 不匹配：实际 {source_hash}，预期 {EXPECTED_SOURCE_SHA256}"
        )

    unicodes = build_retention_unicodes(repo_root)
    font = TTFont(BytesIO(source), recalcTimestamp=False)
    cmap = font.getBestCmap() or {}
    covered = unicodes.intersection(cmap.keys())

    # 第一步：先按字符集子集化，显著减少后续字重实例化计算量。
    options = Options()
    options.layout_features = list(KEEP_LAYOUT_FEATURES)
    options.drop_tables = list(set(options.drop_tables) | set(DROP_TABLES))
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.hinting = False
    options.desubroutinize = False

    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=covered)
    subsetter.subset(font)

    # 第二步：将可变字重轴收缩至 400..700（默认 400），保留全站 400/450/600/700 连续字重。
    instancer.instantiateVariableFont(
        font,
        {"wght": (400, 400, 700)},
        inplace=True,
        optimize=True,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(output_path))
    out_bytes = output_path.stat().st_size
    out_hash = sha256_file(output_path)

    # 写出后立即重新解析校验轴范围与核心字形完整性。
    verify_font = TTFont(str(output_path))
    verify_axes = [
        (axis.axisTag, axis.minValue, axis.defaultValue, axis.maxValue)
        for axis in verify_font["fvar"].axes
    ]
    if verify_axes != [("wght", 400, 400, 700)]:
        raise RuntimeError(f"裁剪结果的可变字重范围错误：{verify_axes}")
    verify_cmap = verify_font.getBestCmap() or {}
    if covered.difference(verify_cmap):
        raise RuntimeError("裁剪结果缺少源字体已覆盖的目标码位")
    sample_text = "86-エイティシックス- 踏み躙られるだけの花 04:26 / 23:41 ★♪♥"
    missing = [ch for ch in sample_text if ch != " " and ord(ch) not in verify_cmap]
    if missing:
        raise RuntimeError(f"裁剪结果缺少必要校验字形：{''.join(missing)}")

    print(f"源字体摘要：{source_hash}")
    print(f"目标保留码位数：{len(unicodes)}，源字体命中码位数：{len(covered)}")
    print(f"产物路径：{output_path}")
    print(f"产物字形数：{len(verify_font.getGlyphOrder())}，有效码位数：{len(verify_cmap)}")
    print(f"产物字重轴：{verify_axes}")
    print(f"产物大小：{out_bytes} 字节（{out_bytes / (1024 * 1024):.2f} MiB）")
    print(f"产物摘要：{out_hash}")


def main() -> None:
    """解析命令行参数并启动双维字体裁剪流程。"""
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Konata v3 双维字体子集化构建工具")
    parser.add_argument(
        "--input",
        type=Path,
        help=f"源可变字体路径，默认从 Git 提交 {SOURCE_REVISION} 读取",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repo_root / "apps/konata/assets/fonts/KonataNotoCJK-VF.ttf",
        help="裁剪后输出字体路径",
    )
    args = parser.parse_args()
    subset_variable_font(
        input_path=args.input,
        output_path=args.output,
        repo_root=repo_root,
    )


if __name__ == "__main__":
    main()
