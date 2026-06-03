#!/usr/bin/env python3
"""
rosetta_best_pose.py
从 Rosetta score 文件（.sc）中按指定列排序，输出最优构象的文件名。

用法：
  python3 rosetta_best_pose.py score.sc [sort_col] [n_top] [--ascending]

参数：
  score.sc   — Rosetta 输出的打分文件
  sort_col   — 排序列名（默认 total_score）；I_sc 用于精修阶段排序
  n_top      — 输出的 Top 条目数（默认 1）
  --ascending — 使用升序排列（Rosetta 能量越低越好，默认升序）

输出（标准输出）：
  每行输出一个构象文件名（description 列）
"""

import sys
import os


def parse_score_file(score_file):
    """
    解析 Rosetta .sc 文件。
    第 1 行为 SCORE: 标签行（跳过）
    第 2 行为列名
    第 3 行起为数据
    返回 (headers, rows) 其中 rows 为 dict 列表。
    """
    headers = []
    rows = []

    with open(score_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if parts[0] == "SCORE:":
                parts = parts[1:]       # 去掉 "SCORE:" 前缀
                if not headers:
                    headers = parts     # 第一次遇到 → 列名行
                else:
                    if len(parts) == len(headers):
                        row = dict(zip(headers, parts))
                        rows.append(row)

    return headers, rows


def best_poses(score_file, sort_col="total_score", n_top=1, ascending=True):
    """
    返回按 sort_col 排序的前 n_top 条目的 description 列表。
    """
    headers, rows = parse_score_file(score_file)

    if not rows:
        raise ValueError(f"打分文件中未找到数据行: {score_file}")

    if sort_col not in headers:
        print(
            f"[rosetta_best_pose] 警告: 列 '{sort_col}' 不存在，"
            f"可用列: {headers}",
            file=sys.stderr,
        )
        # 回退到 total_score
        sort_col = "total_score" if "total_score" in headers else headers[0]

    try:
        sorted_rows = sorted(
            rows,
            key=lambda r: float(r.get(sort_col, 0)),
            reverse=not ascending,
        )
    except ValueError as e:
        raise ValueError(f"排序列 '{sort_col}' 含非数值数据: {e}")

    top_rows = sorted_rows[:n_top]
    return [r.get("description", r.get("decoy", "")) for r in top_rows]


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    score_file = sys.argv[1]
    sort_col = sys.argv[2] if len(sys.argv) > 2 else "total_score"
    n_top = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    ascending = "--ascending" in sys.argv or "--asc" in sys.argv or True
    # Rosetta 能量：total_score / I_sc 均为越低越好 → 升序
    if "--descending" in sys.argv or "--desc" in sys.argv:
        ascending = False

    try:
        names = best_poses(score_file, sort_col, n_top, ascending)
        for name in names:
            print(name)
    except Exception as e:
        print(f"[rosetta_best_pose] 错误: {e}", file=sys.stderr)
        sys.exit(1)
