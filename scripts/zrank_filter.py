#!/usr/bin/env python3
"""
zrank_filter.py
解析 ZRANK 输出文件，从 zdock.out 中提取评分最高的 Top-K 预测，
生成可直接供 create.pl 使用的过滤后 zdock.out 文件。

用法：
  python3 zrank_filter.py \
      zdock.out zdock.out.zr.out filtered_topK.out [top_k]

输出：
  - filtered_topK.out：含 Top-K 预测的 zdock.out（已按 ZRANK 分数排序）
  - 标准输出中打印排名列表及 ZRANK 分数
"""

import sys


def parse_zdock_header_lines(lines):
    """
    解析 zdock.out 文件头，返回 (header_lines, prediction_lines)。
    header 包含 N/spacing/switch、随机旋转行、受体路径行、配体路径行。
    """
    parts0 = lines[0].split()
    switch_num = parts0[2] if len(parts0) > 2 else ""

    header_size = 1          # 第 0 行：N spacing switch
    if switch_num:
        header_size += 1     # 受体随机旋转行（仅当 switch_num != ""）
    header_size += 1         # 配体随机旋转行
    header_size += 1         # 受体路径行
    header_size += 1         # 配体路径行

    return lines[:header_size], lines[header_size:]


def parse_zrank_scores(zrank_file):
    """
    解析 ZRANK 输出文件（每行：预测编号<空格>分数）。
    返回 {pred_index_0based: score} 字典。
    """
    scores = {}
    with open(zrank_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                pred_num = int(parts[0])    # 1-based
                score = float(parts[1])
                scores[pred_num - 1] = score  # 转为 0-based 索引
            except ValueError:
                continue
    return scores


def filter_top_k(zdock_file, zrank_file, output_file, top_k=5):
    """
    从 zdock.out 与 ZRANK 输出中提取 Top-K 预测，写入 output_file。
    返回 (sorted_0based_indices, scores_dict)。
    """
    with open(zdock_file) as f:
        all_lines = f.readlines()

    header, predictions = parse_zdock_header_lines(all_lines)
    scores = parse_zrank_scores(zrank_file)

    if not scores:
        raise ValueError(f"ZRANK 输出文件为空或格式不正确: {zrank_file}")

    # 按 ZRANK 分数升序排列（越小越好），取前 top_k
    n_available = min(len(scores), len(predictions))
    sorted_indices = sorted(
        [i for i in scores if i < n_available],
        key=lambda i: scores[i]
    )[:top_k]

    # 写入过滤后的 zdock.out
    with open(output_file, "w") as f:
        f.writelines(header)
        for idx in sorted_indices:
            f.write(predictions[idx])

    print(f"[zrank_filter] Top {len(sorted_indices)} 预测（ZRANK 评分，越低越好）:")
    print(f"{'Rank':>5}  {'ZDOCK#':>7}  {'ZRANK_Score':>12}  {'ZDOCK_Score':>12}")
    print("-" * 44)
    for rank, idx in enumerate(sorted_indices, 1):
        pred_line = predictions[idx]
        parts = pred_line.split()
        zdock_score = parts[6] if len(parts) > 6 else "N/A"
        print(
            f"{rank:>5}  {idx + 1:>7}  {scores[idx]:>12.4f}  {zdock_score:>12}"
        )

    return sorted_indices, scores


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)

    zdock_file = sys.argv[1]
    zrank_file = sys.argv[2]
    output_file = sys.argv[3]
    top_k = int(sys.argv[4]) if len(sys.argv) > 4 else 5

    indices, _ = filter_top_k(zdock_file, zrank_file, output_file, top_k)

    # 以 1-based 格式打印索引，供 shell 脚本读取
    print("\n[zrank_filter] ZDOCK 预测编号（1-based），供 create.pl 使用:")
    print(" ".join(str(i + 1) for i in indices))
