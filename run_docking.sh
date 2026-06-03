#!/usr/bin/env bash
# =============================================================================
# run_docking.sh — 蛋白-蛋白对接全流程脚本
#
# 工作流：结构准备 → ZDOCK 全局刚性对接 → ZRANK 重打分 →
#          Rosetta 局部对接 → 精修 → FastRelax → 界面分析
#
# 用法：
#   ./run_docking.sh <receptor.pdb> <ligand.pdb> [选项]
#
# 选项：
#   --top-n   N     ZDOCK 生成的预测总数
#   --zrank-n N     ZRANK 重打分的预测数
#   --ros-n   N     送入 Rosetta 精修的 Top 构象数
#   --nstruct N     Rosetta docking_protocol 构象数
#   --refine-n N    Rosetta local_refine 构象数
#   --relax-n N     FastRelax 构象数
#   --skip-rosetta  仅运行至 ZRANK 阶段，跳过 Rosetta 步骤
#   --from-step N   从第 N 步继续（1-9），跳过已完成步骤
#   --allow-parallel-zdock  允许与其他正在运行的 ZDOCK 任务并行
#
# 示例：
#   ./run_docking.sh data/AF-Q86BF9.pdb data/AF-Q9W3I5.pdb
#   ./run_docking.sh data/AF-Q86BF9.pdb data/AF-Q9W3I5.pdb --ros-n 3 --nstruct 500
# =============================================================================

set -euo pipefail

# 当前正在执行的长任务子进程 PID（用于 Ctrl+C 中断）
ACTIVE_CHILD_PID=""

# ─── 路径常量 ──────────────────────────────────────────────────────────────
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZDOCK_HOST_DIR="${WORKSPACE}/zdock3.0.2_linux_x64"   # 宿主机路径
ZRANK_BIN="${WORKSPACE}/zrank_linux_64bit/zrank"
SCRIPTS_DIR="${WORKSPACE}/scripts"
JOBS_DIR="${WORKSPACE}/jobs"
COMPOSE_PROJECT="cadd_terminal_expri"
ZDOCK_REQUIRED_BINS=(
    "${ZDOCK_HOST_DIR}/mark_sur"
    "${ZDOCK_HOST_DIR}/zdock"
    "${ZDOCK_HOST_DIR}/create_lig"
    "${ZDOCK_HOST_DIR}/uniCHARMM"
    "${ZDOCK_HOST_DIR}/create.pl"
    "${ZDOCK_HOST_DIR}/block.pl"
)

# ─── 默认参数 ─────────────────────────────────────────────────────────────
TOP_N_ZDOCK=2000      # ZDOCK 预测总数
ZRANK_N=100          # ZRANK 重打分数量（取 ZDOCK top-N 中的前 ZRANK_N）
ROS_N=5              # 送入 Rosetta 的候选数
NSTRUCT_DOCK=20    # Rosetta docking_protocol 构象数
NSTRUCT_REFINE=10   # Rosetta local_refine 构象数
NSTRUCT_RELAX=5      # FastRelax 构象数
SKIP_ROSETTA=false
FROM_STEP=1
ALLOW_PARALLEL_ZDOCK=false

# ─── 参数解析 ─────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
    sed -n '/^# 用法/,/^$/p' "$0"
    exit 1
fi

RECEPTOR_PDB="$(realpath "$1")"
LIGAND_PDB="$(realpath "$2")"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top-n)    TOP_N_ZDOCK="$2"; shift 2 ;;
        --zrank-n)  ZRANK_N="$2"; shift 2 ;;
        --ros-n)    ROS_N="$2"; shift 2 ;;
        --nstruct)  NSTRUCT_DOCK="$2"; shift 2 ;;
        --refine-n) NSTRUCT_REFINE="$2"; shift 2 ;;
        --relax-n)  NSTRUCT_RELAX="$2"; shift 2 ;;
        --skip-rosetta) SKIP_ROSETTA=true; shift ;;
        --from-step) FROM_STEP="$2"; shift 2 ;;
        --allow-parallel-zdock) ALLOW_PARALLEL_ZDOCK=true; shift ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
done

# ─── 作业目录 ─────────────────────────────────────────────────────────────
REC_ID="$(basename "${RECEPTOR_PDB%.pdb}")"
LIG_ID="$(basename "${LIGAND_PDB%.pdb}")"
JOB_ID="${REC_ID}__${LIG_ID}"
JOB_DIR="${JOBS_DIR}/${JOB_ID}"
LOCK_FILE="${JOB_DIR}/.pipeline.lock"

prepare_job_dir() {
    if [[ -d "${JOB_DIR}" ]]; then
        if [[ -f "${LOCK_FILE}" ]]; then
            local lock_pid
            lock_pid="$(awk -F= '/^pid=/{print $2; exit}' "${LOCK_FILE}" 2>/dev/null || true)"

            if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
                local lock_cmd
                lock_cmd="$(tr '\0' ' ' < "/proc/${lock_pid}/cmdline" 2>/dev/null || true)"
                if [[ "${lock_cmd}" == *run_docking.sh* ]]; then
                    echo "[$(date +%H:%M:%S)]   ✗ 检测到同名项目正在运行（PID ${lock_pid}）：${JOB_ID}"
                    echo "[$(date +%H:%M:%S)]   ✗ 当前任务已终止，避免同名项目并发覆盖"
                    exit 1
                fi
            fi

            echo "[$(date +%H:%M:%S)]   ℹ 检测到同名项目存在但未运行（锁文件过期），将覆写目录: ${JOB_DIR}"
        fi

        if [[ "${FROM_STEP}" -gt 1 ]]; then
            echo "[$(date +%H:%M:%S)]   ℹ 复用现有项目目录，从步骤 ${FROM_STEP} 继续: ${JOB_DIR}"
        else
            if [[ ! -f "${LOCK_FILE}" ]]; then
                echo "[$(date +%H:%M:%S)]   ℹ 检测到同名项目目录存在，将覆写目录: ${JOB_DIR}"
            fi
            rm -rf "${JOB_DIR}"
        fi
    elif [[ "${FROM_STEP}" -gt 1 ]]; then
        echo "[$(date +%H:%M:%S)]   ✗ 目标项目目录不存在，无法从步骤 ${FROM_STEP} 继续: ${JOB_DIR}"
        exit 1
    fi

    mkdir -p "${JOB_DIR}"/{00_prep,01_zdock,02_zrank,03_complexes,04_rosetta_dock,05_rosetta_refine,06_rosetta_relax,07_interface}

    cat > "${LOCK_FILE}" <<EOF
pid=$$
job_id=${JOB_ID}
started_at=$(date +%Y-%m-%dT%H:%M:%S%z)
EOF
}

prepare_job_dir

LOG_FILE="${JOB_DIR}/pipeline.log"

# ─── 日志函数 ─────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG_FILE}"; }
info() { log "  ℹ $*"; }
ok()   { log "  ✓ $*"; }
err()  { log "  ✗ $*"; exit 1; }

step_done()  { [[ -f "${JOB_DIR}/.step_${1}.done" ]]; }
mark_done()  { touch "${JOB_DIR}/.step_${1}.done"; ok "步骤 $1 完成"; }

step9_outputs_ready() {
    local iface_dir="${JOB_DIR}/07_interface"
    local i
    local analyzed=0

    for i in $(seq 1 "${ROS_N}"); do
        local best_relaxed="${JOB_DIR}/06_rosetta_relax/candidate_${i}/best_relaxed.pdb"
        [[ -f "${best_relaxed}" ]] || \
            best_relaxed="${JOB_DIR}/05_rosetta_refine/candidate_${i}/best_refine.pdb"
        [[ -f "${best_relaxed}" ]] || continue

        analyzed=1
        [[ -s "${iface_dir}/candidate_${i}/interface_score.sc" ]] || return 1
    done

    [[ "${analyzed}" -eq 1 ]]
}

should_run() {
    local step="$1"

    [[ "${step}" -ge "${FROM_STEP}" ]] || return 1

    if ! step_done "${step}"; then
        return 0
    fi

    case "${step}" in
        9)
            ! step9_outputs_ready
            ;;
        *)
            return 1
            ;;
    esac
}

check_running_zdock_jobs() {
    # 默认禁止并行 ZDOCK，避免多个重任务抢占 CPU 导致“看似卡住”
    [[ "${ALLOW_PARALLEL_ZDOCK}" == "true" ]] && return 0

    local running
    running="$(docker ps \
        --filter "label=com.docker.compose.project=cadd_terminal_expri" \
        --filter "label=com.docker.compose.service=zdock" \
        --filter "status=running" \
        --format '{{.Names}}\t{{.RunningFor}}')"

    if [[ -n "${running}" ]]; then
        log "检测到已有 ZDOCK 任务在运行："
        while IFS= read -r line; do
            [[ -n "${line}" ]] && log "  - ${line}"
        done <<< "${running}"
        err "为避免任务互相抢占资源，已阻止本次启动。若确认要并行运行，请添加参数: --allow-parallel-zdock"
    fi
}

# ─── 中断处理与可中断执行封装 ─────────────────────────────────────────────
cleanup_active_tasks() {
    local containers

    containers="$(docker ps \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
        --format '{{.Names}} {{.Label "com.docker.compose.service"}}' \
        | awk '$2 == "zdock" || $2 == "rosetta" {print $1}')"

    if [[ -n "${containers}" ]]; then
        while IFS= read -r container; do
            [[ -n "${container}" ]] || continue
            log "  ↳ 停止容器: ${container}"
            docker kill "${container}" >/dev/null 2>&1 || true
        done <<< "${containers}"
    fi

    # 兜底清理宿主机上可能残留的长任务进程
    pkill -KILL -f "${ZRANK_BIN}" >/dev/null 2>&1 || true
    pkill -KILL -f "${ZDOCK_HOST_DIR}/zdock" >/dev/null 2>&1 || true
    pkill -KILL -f "${ZDOCK_HOST_DIR}/create_lig" >/dev/null 2>&1 || true
    pkill -KILL -f "docking_protocol" >/dev/null 2>&1 || true
    pkill -KILL -f "relax" >/dev/null 2>&1 || true
    pkill -KILL -f "InterfaceAnalyzer" >/dev/null 2>&1 || true
}

on_interrupt() {
    local sig="$1"
    log ""
    log "收到 ${sig}，正在中断当前任务并清理子进程..."

    if [[ -n "${ACTIVE_CHILD_PID}" ]] && kill -0 "${ACTIVE_CHILD_PID}" 2>/dev/null; then
        # 优先向子进程组发送 INT，确保 docker/rosetta 前台任务及时停止
        kill -INT "-${ACTIVE_CHILD_PID}" 2>/dev/null || kill -INT "${ACTIVE_CHILD_PID}" 2>/dev/null || true
        kill -TERM "-${ACTIVE_CHILD_PID}" 2>/dev/null || kill -TERM "${ACTIVE_CHILD_PID}" 2>/dev/null || true
        kill -KILL "-${ACTIVE_CHILD_PID}" 2>/dev/null || kill -KILL "${ACTIVE_CHILD_PID}" 2>/dev/null || true
    fi

    # 兜底：清理当前脚本派生的子进程
    pkill -P $$ >/dev/null 2>&1 || true
    cleanup_active_tasks
    exit 130
}

run_interruptible() {
    "$@" &
    ACTIVE_CHILD_PID=$!
    wait "${ACTIVE_CHILD_PID}"
    local rc=$?
    ACTIVE_CHILD_PID=""
    return "$rc"
}

cleanup_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_pid
        lock_pid="$(awk -F= '/^pid=/{print $2; exit}' "${LOCK_FILE}" 2>/dev/null || true)"
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${LOCK_FILE}"
        fi
    fi
}

trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM
trap 'cleanup_lock' EXIT

# ─── Docker 封装函数 ───────────────────────────────────────────────────────
# 在 zdock 容器中执行命令（工作目录为 /work/zdock3.0.2_linux_x64）
zdock_run() {
    cd "${WORKSPACE}"
    run_interruptible docker compose run --rm \
        --workdir /work/zdock3.0.2_linux_x64 \
        zdock bash -c "$1"
}

# 在 rosetta 容器中执行命令（工作目录为参数2指定的路径）
rosetta_run() {
    local workdir="$1"
    shift
    cd "${WORKSPACE}"
    run_interruptible docker compose run --rm \
        --workdir "$workdir" \
    rosetta bash -o pipefail -c "$1"
}

# ─── 步骤 1：结构准备 ─────────────────────────────────────────────────────
step1_prep() {
    log "═══ 步骤 1：结构准备 ═══"
    local prep_dir="${JOB_DIR}/00_prep"
    local rec_clean="${prep_dir}/receptor_clean.pdb"
    local lig_clean="${prep_dir}/ligand_clean.pdb"

    # 清洗 PDB：仅保留 ATOM 记录，去除水分子（HOH）、HETATM
    # 受体保持链 A，配体链改为 B
    python3 - <<PYEOF
import sys, re

def clean_pdb(src, dst, chain_id):
    """保留 ATOM 记录，去除水/HETATM，重置 B-factor，设置链 ID"""
    kept = 0
    with open(src) as f, open(dst, 'w') as out:
        for line in f:
            if not line.startswith('ATOM'):
                continue
            res_name = line[17:20].strip()
            if res_name in ('HOH', 'WAT', 'SOL', 'TIP'):
                continue
            # 设置链 ID（列 22，0-indexed 21）
            line = line[:21] + chain_id + line[22:]
            # 重置占位率（1.00）和温度因子（0.00）
            line = line[:54] + '  1.00' + '  0.00' + '          \n'
            out.write(line)
            kept += 1
        out.write('TER\nEND\n')
    print(f'  {dst}: 保留 {kept} 个 ATOM 记录（链 {chain_id}）')

clean_pdb('${RECEPTOR_PDB}', '${rec_clean}', 'A')
clean_pdb('${LIGAND_PDB}', '${lig_clean}', 'B')
PYEOF

    info "受体: $(grep -c '^ATOM' "${rec_clean}") 个原子（链 A）"
    info "配体: $(grep -c '^ATOM' "${lig_clean}") 个原子（链 B）"

    # 在 ZDOCK 容器中运行 mark_sur（需要 uniCHARMM 在同目录）
    local rel_prep="../jobs/${JOB_ID}/00_prep"
    local rel_rec_m="${rel_prep}/receptor_m.pdb"
    local rel_lig_m="${rel_prep}/ligand_m.pdb"

    info "运行 mark_sur（ZDOCK 容器）..."
    zdock_run "mark_sur ${rel_prep}/receptor_clean.pdb ${rel_rec_m} && \
               mark_sur ${rel_prep}/ligand_clean.pdb ${rel_lig_m}"

    info "mark_sur 完成，输出: receptor_m.pdb, ligand_m.pdb"
    mark_done 1
}

# ─── 步骤 2：ZDOCK 全局刚性对接 ──────────────────────────────────────────
step2_zdock() {
    log "═══ 步骤 2：ZDOCK 全局刚性对接（默认采样）═══"
    local prep_dir="${JOB_DIR}/00_prep"
    local zdock_dir="${JOB_DIR}/01_zdock"
    local rel_prep="../jobs/${JOB_ID}/00_prep"
    local rel_zdout="../jobs/${JOB_ID}/01_zdock/zdock.out"
    local zdock_rc=0

    info "运行 ZDOCK 对接中（可能耗时 10-30 分钟）..."
    set +e
    zdock_run "zdock \
        -R ${rel_prep}/receptor_m.pdb \
        -L ${rel_prep}/ligand_m.pdb \
        -o ${rel_zdout} \
        -N ${TOP_N_ZDOCK}"
    zdock_rc=$?
    set -e

    if [[ "${zdock_rc}" -ne 0 ]]; then
        if [[ -s "${zdock_dir}/zdock.out" ]]; then
            info "警告: ZDOCK 退出码 ${zdock_rc}，但已生成输出文件，继续后续步骤"
        else
            err "ZDOCK 失败（退出码 ${zdock_rc}），且未检测到有效输出文件"
        fi
    fi

    local n_preds
    n_preds=$(tail -n +5 "${zdock_dir}/zdock.out" | grep -c '.' || true)
    info "ZDOCK 完成：生成 ${n_preds} 个预测构象"
    info "输出文件: ${zdock_dir}/zdock.out"

    mark_done 2
}

# ─── 步骤 3：ZRANK 重打分 ────────────────────────────────────────────────
step3_zrank() {
    log "═══ 步骤 3：ZRANK 重打分（Top ${ZRANK_N} ZDOCK 构象）═══"
    local zdock_out="${JOB_DIR}/01_zdock/zdock.out"
    local zrank_dir="${JOB_DIR}/02_zrank"
    local zdock_for_zrank="${JOB_DIR}/01_zdock/zdock_for_zrank.out"

    # 注意：ZRANK 需要在 zdock3.0.2_linux_x64/ 目录运行，
    # 因为 zdock.out 中的路径是相对于该目录的
    local rel_zdout_for_zrank="../jobs/${JOB_ID}/01_zdock/zdock_for_zrank.out"

    info "运行 ZRANK（宿主机，静态链接二进制）..."

    # 某些 ZDOCK 输出会在头部包含一行 0 向量，ZRANK 可能误将其当作 PDB 路径
    # 兼容策略：为 ZRANK 生成标准化输入，仅移除该零向量行，预测行顺序保持不变
    python3 - <<PYEOF
import re

src = '${zdock_out}'
dst = '${zdock_for_zrank}'

with open(src) as f:
    lines = f.readlines()

removed_zero_line = False
if len(lines) >= 5:
    line2 = lines[2].strip()
    line3 = lines[3].strip()
    line4 = lines[4].strip()

    is_zero_vec = bool(re.match(r'^0(?:\.0+)?\s+0(?:\.0+)?\s+0(?:\.0+)?$', line2))
    has_pdb_paths = ('.pdb' in line3 and '.pdb' in line4)
    if is_zero_vec and has_pdb_paths:
        del lines[2]
        removed_zero_line = True

with open(dst, 'w') as out:
    out.writelines(lines)

print('[zrank_prep] removed_zero_line=' + ('yes' if removed_zero_line else 'no'))
PYEOF

    cd "${ZDOCK_HOST_DIR}"
    run_interruptible "${ZRANK_BIN}" "${rel_zdout_for_zrank}" 1 "${ZRANK_N}"
    cd "${WORKSPACE}"

    # ZRANK 输出文件（自动命名为 {input}.zr.out）
    local zrout="${JOB_DIR}/01_zdock/zdock_for_zrank.out.zr.out"
    local zrout_compat="${JOB_DIR}/01_zdock/zdock.out.zr.out"
    [[ -s "${zrout}" ]] || err "ZRANK 输出文件未生成或为空: ${zrout}"
    cp "${zrout}" "${zrout_compat}"

    info "ZRANK 完成，生成: zdock.out.zr.out（已做输入标准化兼容）"

    # 解析 ZRANK 结果，生成 Top-K 过滤后的 zdock.out
    local filtered="${zrank_dir}/zdock_top${ROS_N}.out"
    python3 "${SCRIPTS_DIR}/zrank_filter.py" \
        "${zdock_out}" "${zrout_compat}" "${filtered}" "${ROS_N}" \
        2>&1 | tee -a "${LOG_FILE}"

    info "Top-${ROS_N} 预测已写入: ${filtered}"
    mark_done 3
}

# ─── 步骤 4：提取 Top-K 复合物 ──────────────────────────────────────────
step4_extract() {
    log "═══ 步骤 4：提取 Top-${ROS_N} 复合物 ═══"
    local zrank_dir="${JOB_DIR}/02_zrank"
    local complex_dir="${JOB_DIR}/03_complexes"
    local filtered="${zrank_dir}/zdock_top${ROS_N}.out"
    local zdock_out="${JOB_DIR}/01_zdock/zdock.out"

    # create.pl 需要在 zdock3.0.2_linux_x64/ 容器目录下运行
    # 并且 create_lig 必须在当前目录（容器已有）
    local rel_filtered="../jobs/${JOB_ID}/02_zrank/zdock_top${ROS_N}.out"

    info "运行 create.pl 生成 ${ROS_N} 个复合物 PDB..."
    zdock_run "chmod 755 ./create_lig ./create.pl ./block.pl ./mark_sur ./zdock ./uniCHARMM && \
               create.pl ${rel_filtered} ${ROS_N}"

    # create.pl 将 complex.N.pdb 创建在容器 CWD = /work/zdock3.0.2_linux_x64/
    # 在宿主机上即 ZDOCK_HOST_DIR/complex.N.pdb
    for i in $(seq 1 "${ROS_N}"); do
        local src="${ZDOCK_HOST_DIR}/complex.${i}.pdb"
        [[ -f "${src}" ]] || { info "警告: complex.${i}.pdb 未生成，跳过"; continue; }

        local dst_raw="${complex_dir}/complex_raw_${i}.pdb"
        local dst="${complex_dir}/complex_rosetta_${i}.pdb"

        # 移动原始复合物文件
        mv "${src}" "${dst_raw}"

        # 后处理：链 A=受体，链 B=配体，清理非标准列
        # 最后参数传入 zdock_base 目录，供解析 zdock.out 中的相对路径
        python3 "${SCRIPTS_DIR}/complex_to_rosetta.py" \
            "${dst_raw}" "${zdock_out}" "${dst}" \
            "A" "B" "${ZDOCK_HOST_DIR}" \
            2>&1 | tee -a "${LOG_FILE}"

        info "候选 ${i}: ${dst}"
    done

    mark_done 4
}

# ─── 步骤 5：Rosetta 预打包（Prepack）────────────────────────────────────
step5_prepack() {
    log "═══ 步骤 5：Rosetta docking_prepack_protocol ═══"
    local complex_dir="${JOB_DIR}/03_complexes"
    local dock_dir="${JOB_DIR}/04_rosetta_dock"

    for i in $(seq 1 "${ROS_N}"); do
        local input="${complex_dir}/complex_rosetta_${i}.pdb"
        [[ -f "${input}" ]] || continue

        local cand_dir="${dock_dir}/candidate_${i}"
        mkdir -p "${cand_dir}/prepack"
        cp "${input}" "${cand_dir}/prepack/input.pdb"

        info "候选 ${i}: 运行 docking_prepack_protocol..."
        local rel_cand="/work/jobs/${JOB_ID}/04_rosetta_dock/candidate_${i}/prepack"
        rosetta_run "${rel_cand}" \
            "docking_prepack_protocol \
                -s input.pdb \
                -partners A_B \
                -ex1 -ex2aro \
                -use_input_sc \
                -out:file:scorefile prepack_score.sc \
                2>&1 | tail -5"

        # docking_prepack_protocol 输出为 input_0001.pdb
        local prepacked="${cand_dir}/prepack/input_0001.pdb"
        if [[ ! -f "${prepacked}" ]]; then
            # 某些版本输出名称可能不同，寻找最新的 pdb
            prepacked="$(ls -t "${cand_dir}/prepack/"*.pdb 2>/dev/null | grep -v '^input\.pdb$' | head -1 || true)"
        fi

        if [[ -z "${prepacked}" || ! -f "${prepacked}" ]]; then
            info "警告: 候选 ${i} prepack 未找到输出，使用原始输入"
            cp "${input}" "${cand_dir}/prepacked.pdb"
        else
            cp "${prepacked}" "${cand_dir}/prepacked.pdb"
            info "候选 ${i}: prepack 完成 → ${cand_dir}/prepacked.pdb"
        fi
    done

    mark_done 5
}

# ─── 步骤 6：Rosetta 局部对接（docking_protocol）────────────────────────
step6_dock() {
    log "═══ 步骤 6：Rosetta docking_protocol（${NSTRUCT_DOCK} 构象/候选）═══"
    local dock_dir="${JOB_DIR}/04_rosetta_dock"

    for i in $(seq 1 "${ROS_N}"); do
        local cand_dir="${dock_dir}/candidate_${i}"
        local prepacked="${cand_dir}/prepacked.pdb"
        [[ -f "${prepacked}" ]] || continue

        mkdir -p "${cand_dir}/docking"
        cp "${prepacked}" "${cand_dir}/docking/prepacked.pdb"

        info "候选 ${i}: docking_protocol（${NSTRUCT_DOCK} 构象，可能耗时较长）..."
        local rel_dock="/work/jobs/${JOB_ID}/04_rosetta_dock/candidate_${i}/docking"
        rosetta_run "${rel_dock}" \
            "docking_protocol \
                -s prepacked.pdb \
                -nstruct ${NSTRUCT_DOCK} \
                -partners A_B \
                -dock_pert 3 8 \
                -ex1 -ex2aro \
                -use_input_sc \
                -out:file:scorefile score.sc \
                -out:suffix _dock \
                2>&1 | grep -E 'protocols|core|SCORE:.*total' | tail -10; \
                exit \${PIPESTATUS[0]}"

        # 选取 total_score 最低的构象
        local score_sc="${cand_dir}/docking/score.sc"
        if [[ -f "${score_sc}" ]]; then
            local best_name
            best_name="$(python3 "${SCRIPTS_DIR}/rosetta_best_pose.py" \
                "${score_sc}" total_score 1 2>>"${LOG_FILE}")"
            local best_pdb="${cand_dir}/docking/${best_name}.pdb"
            if [[ -f "${best_pdb}" ]]; then
                cp "${best_pdb}" "${cand_dir}/best_dock.pdb"
                info "候选 ${i}: 最优对接构象 → ${best_name} (total_score)"
            else
                # 找不到具名文件时取最新的 pdb（Rosetta 输出命名规则变体）
                local fallback
                fallback="$(ls -t "${cand_dir}/docking/"*_dock*.pdb 2>/dev/null | head -1 || true)"
                [[ -n "${fallback}" ]] && cp "${fallback}" "${cand_dir}/best_dock.pdb" \
                    && info "候选 ${i}: 回退使用最新对接构象"
            fi
        fi
    done

    mark_done 6
}

# ─── 步骤 7：Rosetta 局部精修（docking_local_refine）────────────────────
step7_refine() {
    log "═══ 步骤 7：Rosetta docking_local_refine（${NSTRUCT_REFINE} 构象/候选）═══"
    local dock_dir="${JOB_DIR}/04_rosetta_dock"
    local refine_dir="${JOB_DIR}/05_rosetta_refine"

    for i in $(seq 1 "${ROS_N}"); do
        local best_dock="${dock_dir}/candidate_${i}/best_dock.pdb"
        [[ -f "${best_dock}" ]] || continue

        local cand_ref="${refine_dir}/candidate_${i}"
        mkdir -p "${cand_ref}"
        cp "${best_dock}" "${cand_ref}/best_dock.pdb"

        info "候选 ${i}: docking_local_refine（${NSTRUCT_REFINE} 构象）..."
        local rel_ref="/work/jobs/${JOB_ID}/05_rosetta_refine/candidate_${i}"
        rosetta_run "${rel_ref}" \
            "docking_protocol \
                -s best_dock.pdb \
                -nstruct ${NSTRUCT_REFINE} \
                -partners A_B \
                -docking_local_refine \
                -ex1 -ex2aro -ex1aro -ex2 \
                -use_input_sc \
                -out:file:scorefile score.sc \
                -out:suffix _refine \
                2>&1 | grep -E 'SCORE:.*total' | tail -5; \
                exit \${PIPESTATUS[0]}"

        # 选取 I_sc（interface score）最低的构象
        local score_sc="${cand_ref}/score.sc"
        if [[ -f "${score_sc}" ]]; then
            local best_name
            best_name="$(python3 "${SCRIPTS_DIR}/rosetta_best_pose.py" \
                "${score_sc}" I_sc 1 2>>"${LOG_FILE}" || \
                python3 "${SCRIPTS_DIR}/rosetta_best_pose.py" \
                "${score_sc}" total_score 1 2>>"${LOG_FILE}")"
            local best_pdb="${cand_ref}/${best_name}.pdb"
            if [[ -f "${best_pdb}" ]]; then
                cp "${best_pdb}" "${cand_ref}/best_refine.pdb"
                info "候选 ${i}: 最优精修构象 → ${best_name} (I_sc)"
            else
                local fallback
                fallback="$(ls -t "${cand_ref}/"*_refine*.pdb 2>/dev/null | head -1 || true)"
                [[ -n "${fallback}" ]] && cp "${fallback}" "${cand_ref}/best_refine.pdb"
            fi
        fi
    done

    mark_done 7
}

# ─── 步骤 8：FastRelax ───────────────────────────────────────────────────
step8_relax() {
    log "═══ 步骤 8：Rosetta FastRelax（${NSTRUCT_RELAX} 构象/候选）═══"
    local refine_dir="${JOB_DIR}/05_rosetta_refine"
    local relax_dir="${JOB_DIR}/06_rosetta_relax"

    for i in $(seq 1 "${ROS_N}"); do
        local best_ref="${refine_dir}/candidate_${i}/best_refine.pdb"
        [[ -f "${best_ref}" ]] || continue

        local cand_relax="${relax_dir}/candidate_${i}"
        mkdir -p "${cand_relax}"
        cp "${best_ref}" "${cand_relax}/best_refine.pdb"

        info "候选 ${i}: FastRelax（${NSTRUCT_RELAX} 构象）..."
        local rel_relax="/work/jobs/${JOB_ID}/06_rosetta_relax/candidate_${i}"
        rosetta_run "${rel_relax}" \
            "relax \
                -s best_refine.pdb \
                -relax:fast \
                -nstruct ${NSTRUCT_RELAX} \
                -constrain_relax_to_start_coords \
                -ex1 -ex2aro \
                -out:file:scorefile score.sc \
                -out:suffix _relax \
                2>&1 | grep -E 'SCORE:.*total' | tail -5; \
                exit \${PIPESTATUS[0]}"

        local score_sc="${cand_relax}/score.sc"
        if [[ -f "${score_sc}" ]]; then
            local best_name
            best_name="$(python3 "${SCRIPTS_DIR}/rosetta_best_pose.py" \
                "${score_sc}" total_score 1 2>>"${LOG_FILE}")"
            local best_pdb="${cand_relax}/${best_name}.pdb"
            if [[ -f "${best_pdb}" ]]; then
                cp "${best_pdb}" "${cand_relax}/best_relaxed.pdb"
                info "候选 ${i}: FastRelax 最优构象 → ${best_name}"
            else
                local fallback
                fallback="$(ls -t "${cand_relax}/"*_relax*.pdb 2>/dev/null | head -1 || true)"
                [[ -n "${fallback}" ]] && cp "${fallback}" "${cand_relax}/best_relaxed.pdb"
            fi
        fi
    done

    mark_done 8
}

# ─── 步骤 9：界面分析（InterfaceAnalyzer）────────────────────────────────
step9_interface() {
    log "═══ 步骤 9：Rosetta InterfaceAnalyzer ═══"
    local relax_dir="${JOB_DIR}/06_rosetta_relax"
    local iface_dir="${JOB_DIR}/07_interface"
    local analyzed_count=0

    for i in $(seq 1 "${ROS_N}"); do
        local best_relaxed="${relax_dir}/candidate_${i}/best_relaxed.pdb"
        # 如无 relax 结果，尝试用精修结果
        [[ -f "${best_relaxed}" ]] || \
            best_relaxed="${JOB_DIR}/05_rosetta_refine/candidate_${i}/best_refine.pdb"
        [[ -f "${best_relaxed}" ]] || continue
        analyzed_count=$((analyzed_count + 1))

        local cand_iface="${iface_dir}/candidate_${i}"
        mkdir -p "${cand_iface}"
        cp "${best_relaxed}" "${cand_iface}/input.pdb"

        info "候选 ${i}: InterfaceAnalyzer..."
        local rel_iface="/work/jobs/${JOB_ID}/07_interface/candidate_${i}"
        rosetta_run "${rel_iface}" \
            "InterfaceAnalyzer \
                -s input.pdb \
                -interface A_B \
                -pack_separated \
                -out:file:scorefile interface_score.sc \
                2>&1 | tail -10"

        [[ -s "${cand_iface}/interface_score.sc" ]] \
            || err "候选 ${i} InterfaceAnalyzer 未生成结果文件: ${cand_iface}/interface_score.sc"

        info "候选 ${i}: 界面分析完成 → interface_score.sc"
    done

    [[ "${analyzed_count}" -gt 0 ]] || err "步骤 9 未找到可分析的候选结构"

    # 生成汇总表格
    local summary="${iface_dir}/summary.tsv"
    python3 - <<PYEOF
import os, glob

iface_dir = '${iface_dir}'
summary_file = '${summary}'

header_written = False
rows = []

for i in range(1, ${ROS_N} + 1):
    sc_file = os.path.join(iface_dir, f'candidate_{i}', 'interface_score.sc')
    if not os.path.exists(sc_file):
        continue
    with open(sc_file) as f:
        headers = []
        for line in f:
            parts = line.strip().split()
            if not parts or parts[0] != 'SCORE:':
                continue
            parts = parts[1:]
            if not headers:
                headers = parts
            elif len(parts) == len(headers):
                row = {'candidate': i}
                row.update(dict(zip(headers, parts)))
                rows.append(row)

if rows:
    all_keys = ['candidate'] + [k for k in rows[0] if k != 'candidate']
    with open(summary_file, 'w') as out:
        out.write('\t'.join(all_keys) + '\n')
        for row in rows:
            out.write('\t'.join(str(row.get(k, 'N/A')) for k in all_keys) + '\n')
    print(f'[汇总] 界面分析汇总 → {summary_file}')
else:
    print('[汇总] 无有效界面分析结果')
PYEOF

    mark_done 9
}

# ─── 最终报告 ─────────────────────────────────────────────────────────────
print_summary() {
    log ""
    log "══════════════════════════════════════════════"
    log "  对接流水线完成！作业目录: ${JOB_DIR}"
    log "══════════════════════════════════════════════"
    log "  目录结构:"
    log "    00_prep/        - 清洗后的 PDB 结构"
    log "    01_zdock/       - ZDOCK 对接结果（zdock.out）"
    log "    02_zrank/       - ZRANK 重打分结果"
    log "    03_complexes/   - Top ${ROS_N} 候选复合物"
    log "    04_rosetta_dock/ - Rosetta 局部对接"
    log "    05_rosetta_refine/ - Rosetta 精修"
    log "    06_rosetta_relax/ - FastRelax 优化"
    log "    07_interface/   - 界面分析结果"
    log ""

    if [[ -f "${JOB_DIR}/07_interface/summary.tsv" ]]; then
        log "  界面分析汇总（关键指标）:"
        python3 - <<PYEOF
summary = '${JOB_DIR}/07_interface/summary.tsv'
try:
    with open(summary) as f:
        lines = f.readlines()
    if len(lines) > 1:
        headers = lines[0].strip().split('\t')
        key_cols = ['candidate', 'total_score', 'dG_separated',
                    'dSASA_int', 'sc_value', 'description']
        cols = [c for c in key_cols if c in headers]
        col_idx = [headers.index(c) for c in cols]
        print('  ' + '\t'.join(cols))
        for line in lines[1:]:
            parts = line.strip().split('\t')
            print('  ' + '\t'.join(parts[i] if i < len(parts) else 'N/A' for i in col_idx))
except Exception as e:
    print(f'  （无法读取汇总文件: {e}）')
PYEOF
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 主流程
# ═══════════════════════════════════════════════════════════════════════════
main() {
    log ""
    log "══════════════════════════════════════════════"
    log "  蛋白-蛋白对接流水线"
    log "  受体: ${REC_ID}  ($(basename "${RECEPTOR_PDB}"))"
    log "  配体: ${LIG_ID}  ($(basename "${LIGAND_PDB}"))"
    log "  作业目录: ${JOB_DIR}"
    log "══════════════════════════════════════════════"

    # 检查必要工具
    [[ -f "${ZRANK_BIN}" ]] || err "ZRANK 二进制不存在: ${ZRANK_BIN}"
    [[ -x "${ZRANK_BIN}" ]] || chmod +x "${ZRANK_BIN}"
    chmod +x "${ZDOCK_REQUIRED_BINS[@]}"
    [[ -f "${RECEPTOR_PDB}" ]] || err "受体 PDB 不存在: ${RECEPTOR_PDB}"
    [[ -f "${LIGAND_PDB}" ]]   || err "配体 PDB 不存在: ${LIGAND_PDB}"

    # Docker 镜像检查
    docker image inspect zdock302:local > /dev/null 2>&1 \
        || err "ZDOCK Docker 镜像 zdock302:local 不存在，请先构建：docker compose build zdock"
    docker image inspect rosettacommons/rosetta:ml-420 > /dev/null 2>&1 \
        || err "Rosetta Docker 镜像 rosettacommons/rosetta:ml-420 不存在，请先拉取"

    check_running_zdock_jobs

    should_run 1 && step1_prep
    should_run 2 && step2_zdock
    should_run 3 && step3_zrank
    should_run 4 && step4_extract

    if [[ "${SKIP_ROSETTA}" == "false" ]]; then
        should_run 5 && step5_prepack
        should_run 6 && step6_dock
        should_run 7 && step7_refine
        should_run 8 && step8_relax
        should_run 9 && step9_interface
    else
        log "（跳过 Rosetta 步骤，已设置 --skip-rosetta）"
    fi

    print_summary
}

main "$@"
