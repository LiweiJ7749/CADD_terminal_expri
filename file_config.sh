# 请先修改这两行
RECEPTOR_PDB=data/AF-Q9W3I5.pdb
LIGAND_PDB=data/AF-Q86BF9.pdb

# 其它参数可按需修改
TOP_N_ZDOCK=500
ZRANK_N=100
ROS_N=5
NSTRUCT_DOCK=100
NSTRUCT_REFINE=100
NSTRUCT_RELAX=5
ALLOW_PARALLEL_ZDOCK=false   # 若想并行ZDOCK则改为true

# 自动生成作业目录等
WORKSPACE=$(pwd)
ZDOCK_HOST_DIR="${WORKSPACE}/zdock3.0.2_linux_x64"
ZRANK_BIN="${WORKSPACE}/zrank_linux_64bit/zrank"
SCRIPTS_DIR="${WORKSPACE}/scripts"
REC_ID=$(basename "${RECEPTOR_PDB%.pdb}")
LIG_ID=$(basename "${LIGAND_PDB%.pdb}")
JOB_ID="${REC_ID}__${LIG_ID}"
JOB_DIR="${WORKSPACE}/jobs/${JOB_ID}"
LOG_FILE="${JOB_DIR}/pipeline.log"

mkdir -p "${JOB_DIR}"/{00_prep,01_zdock,02_zrank,03_complexes,04_rosetta_dock,05_rosetta_refine,06_rosetta_relax,07_interface}