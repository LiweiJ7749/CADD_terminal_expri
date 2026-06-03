# 蛋白-蛋白对接脚本

## 主要脚本：run_docking.sh
**1. 结构准备**。先把输入 PDB 清洗成只保留 ATOM 记录，去掉水和杂原子，并把受体链统一设成 A、配体链设成 B。然后调用 ZDOCK 中的 `mark_sur` 可执行文件生成后续对接需要的表面/几何预处理文件。

**2. ZDOCK 全局刚性对接**。在 Docker 容器里运行 ZDOCK，做大范围的刚体采样，输出 `zdock.out`。

**3. ZRANK 重打分**。对 ZDOCK 的候选对接情况做更合理的排序，然后取前面少量 Top 候选继续往下做。

**4. 提取复合物**。脚本调用 `create.pl `把 Top 候选恢复成具体的复合物 PDB，再用 `complex_to_rosetta.py` 做 Rosetta 兼容化处理，统一链编号和格式，生成后续 Rosetta 能直接用的复合物结构。

**5. Rosetta 预打包**。把侧链和界面环境预整理好，减少后面对接时的初始碰撞和不合理侧链构象。

**6. Rosetta 局部对接**。对每个候选生成多个局部对接构象，然后按 total_score 选出最优对接。可以理解为**在 ZDOCK 已经给出的合理起点上，再做更精细的局部搜索**。

**7. 局部精修**。基于上一步最优构象继续做 docking_local_refine，并优先按 I_sc 选最好构象，如果没有 I_sc 再退回 total_score。

**8. FastRelax**。对精修后的结构做进一步能量优化，尽量让复合物在局部几何上更自然、更稳定，最后按 total_score 挑出最优松弛构象。

**9. 界面分析**。脚本对最终构象跑 `InterfaceAnalyzer`，输出 `interface_score.sc`，并汇总成 `summary.tsv`。

- 注：当前**仓库文件仅支持运行至第4步**，rosetta 软件的 docker 镜像过大。可以在 Wsl 上运行 `docker pull rosettacommons/rosetta:ml-420` 下载，并配置到环境变量中即可

## 辅助脚本: 00pre.sh
对蛋白构象使用 `run_rosetta <pdb文件> InterfaceAnalyzer `进行界面打分

