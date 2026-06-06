#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PDBS=(
  "./data/cluspro_result.pdb"
  "./data/gramm_result.pdb"
  "./data/haddock_result.pdb"
  "./data/zdock_result.pdb"
  "./data/6L1Y_standard.pdb"
)

OUT_DIR="${WORKSPACE}/interface_scores"
mkdir -p "${OUT_DIR}"

CONTAST="${OUT_DIR}/contast.tsv"
: > "${CONTAST}"
TMP_DIR="${OUT_DIR}/_contast_parts"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

for pdb in "${PDBS[@]}"; do
  name="$(basename "${pdb%.pdb}")"
  workdir="/work/interface_scores/${name}"
  mkdir -p "${OUT_DIR}/${name}"
  cp "${pdb}" "${OUT_DIR}/${name}/input.pdb"

  echo "==> ${name}"
  docker compose run --rm \
    --workdir "${workdir}" \
    rosetta bash -o pipefail -c \
    "InterfaceAnalyzer \
        -s input.pdb \
        -interface A_B \
        -pack_separated \
        -out:file:scorefile interface_score.sc \
        2>&1 | tail -10"

  sc="${OUT_DIR}/${name}/interface_score.sc"
  [[ -s "${sc}" ]] || { echo "✗ 无结果: ${name}" >&2; exit 1; }

  # 取 interface_score.sc 里最后一个 SCORE 行作为结果
  header_line="$(grep -m1 '^SCORE:' "${sc}" | sed 's/^SCORE:[[:space:]]*//')"
  data_line="$(grep '^SCORE:' "${sc}" | tail -1 | sed 's/^SCORE:[[:space:]]*//')"

  IFS=$' \t' read -r -a header_arr <<< "${header_line}"
  IFS=$' \t' read -r -a data_arr <<< "${data_line}"

  part_file="${TMP_DIR}/${name}.tsv"
  {
    printf "model"
    for v in "${header_arr[@]}"; do printf "\t%s" "${v}"; done
    printf "\n"
    printf "%s" "${name}"
    for v in "${data_arr[@]}"; do printf "\t%s" "${v}"; done
    printf "\n"
  } > "${part_file}"
done

export TMP_DIR CONTAST
python3 - <<'PYEOF'
from pathlib import Path
import os

parts_dir = Path(os.environ["TMP_DIR"])
out_path = Path(os.environ["CONTAST"])

parts = sorted(parts_dir.glob("*.tsv"))
if not parts:
    raise SystemExit("no parts to merge")

headers = []
rows = []

for part in parts:
    lines = part.read_text().splitlines()
    if len(lines) < 2:
        continue
    header = lines[0].split("\t")
    data = lines[1].split("\t")
    row = dict(zip(header, data))
    # keep order by first appearance
    for col in header:
        if col not in headers:
            headers.append(col)
    rows.append(row)

with out_path.open("w") as out:
  out.write("\t".join(headers) + "\n")
  for row in rows:
    out.write("\t".join(row.get(col, "") for col in headers) + "\n")
PYEOF

echo "完成，汇总文件: ${CONTAST}"