set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESULT_PDBS=(
  "./data/zdock_result.pdb"
  "./data/cluspro_result.pdb"
  "./data/gramm_result.pdb"
  "./data/haddock_result.pdb"
  "./data/frodock_result.pdb"
)

REFERENCE_PDB="./data/6L1Y_standard.pdb"

OUT_DIR="${WORKSPACE}/dockq_analyse"
mkdir -p "${OUT_DIR}"

SUMMARY_TSV="${OUT_DIR}/summary.tsv"

if ! command -v DockQ >/dev/null 2>&1; then
  echo "错误: 未找到 DockQ 命令，请先安装 DockQ。" >&2
  exit 1
fi

if [[ ! -f "${REFERENCE_PDB}" ]]; then
  echo "错误: 参考结构不存在: ${REFERENCE_PDB}" >&2
  exit 1
fi

printf 'model\tbest_dockq\tglobal_dockq\tinterface\tDockQ\tF1\tiRMSD\tLRMSD\tfnat\tfnonnat\tclashes\tmapping\n' > "${SUMMARY_TSV}"

for result_pdb in "${RESULT_PDBS[@]}"; do
  if [[ ! -f "${result_pdb}" ]]; then
    echo "警告: 跳过不存在的结果文件: ${result_pdb}" >&2
    continue
  fi

  model_name="$(basename "${result_pdb}" .pdb)"
  report_txt="${OUT_DIR}/${model_name}.dockq.txt"
  report_json="${OUT_DIR}/${model_name}.dockq.json"

  echo "运行 DockQ: ${model_name}"
  DockQ "${result_pdb}" "${REFERENCE_PDB}" --short --json "${report_json}" | tee "${report_txt}"

  awk -v model_name="${model_name}" 'BEGIN { FS = " " }
    NR == 1 {
      best_dockq = $7
      global_dockq = $7
      split($9, chain_parts, ":")
      model_chains = chain_parts[1]
      native_chains = chain_parts[2]
      interface_name = native_chains
      mapping = ""
      chain_count = length(model_chains)
      if (length(native_chains) < chain_count) {
        chain_count = length(native_chains)
      }
      for (i = 1; i <= chain_count; i++) {
        if (i > 1) {
          mapping = mapping ","
        }
        mapping = mapping substr(native_chains, i, 1) ":" substr(model_chains, i, 1)
      }
    }
    NR == 2 {
      dockq = $2
      irmsd = $4
      lrmsd = $6
      fnat = $8
      fnonnat = $10
      f1 = $12
      clashes = $14
    }
    END {
      print model_name, best_dockq, global_dockq, interface_name, dockq, f1, irmsd, lrmsd, fnat, fnonnat, clashes, mapping
    }' OFS='\t' "${report_txt}" >> "${SUMMARY_TSV}"
done

echo "DockQ 评价完成，汇总文件: ${SUMMARY_TSV}"
