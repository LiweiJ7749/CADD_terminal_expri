#!/usr/bin/env python3
"""
complex_to_rosetta.py
将 ZDOCK create.pl 生成的复合物 PDB 转换为 Rosetta 兼容格式：
  - 受体链保持为 chain A
  - 配体链改为 chain B
  - 重置占位因子与温度因子（B-factor）列为标准 PDB 格式
  - 添加正确的 TER / END 记录

用法：
  python3 complex_to_rosetta.py \
      complex.pdb zdock.out output_rosetta.pdb [rec_chain] [lig_chain]

参数：
  complex.pdb   — create.pl 生成的复合物文件
  zdock.out     — ZDOCK 输出文件（用于解析 switch 标志与蛋白路径）
  output_rosetta.pdb — 输出的 Rosetta 友好 PDB
  rec_chain     — 受体链 ID（默认 A）
  lig_chain     — 配体链 ID（默认 B）
"""

import sys
import os


def parse_zdock_header(zdock_file):
    """解析 zdock.out 文件头，返回 switch_num、receptor 路径、ligand 路径"""
    with open(zdock_file) as f:
        lines = f.readlines()

    parts0 = lines[0].split()
    switch_num = parts0[2] if len(parts0) > 2 else ""

    idx = 1
    if switch_num:          # switch_num != "" → 含受体随机旋转行
        idx += 1            # 跳过受体随机旋转
    idx += 1                # 跳过配体随机旋转

    rec_path = lines[idx].split()[0]
    lig_path = lines[idx + 1].split()[0]

    return switch_num, rec_path, lig_path


def count_atoms(pdb_path, zdock_base=None):
    """
    统计 PDB 文件中的 ATOM 记录数量。
    pdb_path 可能是相对于 zdock3.0.2_linux_x64/ 的路径。
    zdock_base: zdock3.0.2_linux_x64/ 目录的绝对路径（可选）。
    """
    # 候选搜索路径：
    candidates = [pdb_path]
    if zdock_base:
        candidates.append(os.path.join(zdock_base, pdb_path))
    # 脚本所在目录的父目录下的 zdock3.0.2_linux_x64/
    script_parent = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates.append(os.path.join(script_parent, "zdock3.0.2_linux_x64", pdb_path))
    # 也直接尝试相对 CWD 的路径（含 ../）
    candidates.append(os.path.normpath(pdb_path))

    for fullpath in candidates:
        try:
            count = 0
            with open(fullpath) as f:
                for line in f:
                    if line.startswith("ATOM"):
                        count += 1
            return count
        except FileNotFoundError:
            continue
    raise FileNotFoundError(
        f"找不到 PDB 文件（已尝试多个路径）: {pdb_path}"
    )


def process_complex(complex_pdb, zdock_out, output_pdb,
                    rec_chain="A", lig_chain="B", zdock_base=None):
    """
    读取 complex.pdb，根据 zdock.out 确定哪个蛋白在文件前段（受体），
    将前 n_first 个 ATOM 记录分配给 rec_chain，其余分配给 lig_chain。
    同时清理非标准列（ZDOCK mark_sur 格式 → 标准 PDB）。
    zdock_base: zdock3.0.2_linux_x64/ 目录路径，用于解析 zdock.out 中的相对路径。
    """
    switch_num, rec_path, lig_path = parse_zdock_header(zdock_out)

    # create.pl 在 switch_num == "1" 时会互换：
    #   $rec = lig_path 的文件（先 cat 进复合物）
    #   $lig = rec_path 的文件（变换后 cat 进复合物）
    if switch_num == "1":
        first_path = lig_path   # 复合物中第一段
        second_path = rec_path
    else:
        first_path = rec_path
        second_path = lig_path

    # 统计第一段蛋白的原子数，用于确定分界
    n_first = count_atoms(first_path, zdock_base=zdock_base)

    atom_count = 0
    out_lines = []

    with open(complex_pdb) as f:
        for line in f:
            if not line.startswith("ATOM"):
                continue
            atom_count += 1
            chain = rec_chain if atom_count <= n_first else lig_chain

            # 修复链 ID（PDB 格式第 22 列，0-indexed 21）
            line = line[:21] + chain + line[22:]

            # 重置占位率（cols 55-60）和温度因子（cols 61-66）
            # mark_sur 格式这两列存放了 ZDOCK 内部数据，需还原
            line = line[:54] + "  1.00" + "  0.00" + "          \n"
            # 补齐到 66 列后直接换行（Rosetta 不需要后续的元素符号等列）
            out_lines.append(line)

            if atom_count == n_first:
                out_lines.append(f"TER\n")

    out_lines.append("TER\n")
    out_lines.append("END\n")

    with open(output_pdb, "w") as f:
        f.writelines(out_lines)

    n_second = atom_count - n_first
    print(
        f"[complex_to_rosetta] 写入 {atom_count} 个原子 "
        f"({n_first} 受体/{rec_chain}, {n_second} 配体/{lig_chain}) "
        f"→ {output_pdb}"
    )
    return n_first, n_second


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)

    rec_ch = sys.argv[4] if len(sys.argv) > 4 else "A"
    lig_ch = sys.argv[5] if len(sys.argv) > 5 else "B"
    zdock_base_arg = sys.argv[6] if len(sys.argv) > 6 else None

    process_complex(
        complex_pdb=sys.argv[1],
        zdock_out=sys.argv[2],
        output_pdb=sys.argv[3],
        rec_chain=rec_ch,
        lig_chain=lig_ch,
        zdock_base=zdock_base_arg,
    )
