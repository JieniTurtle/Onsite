#!/bin/bash
# main-test-xht.sh - 纯净训练+监控版
# 用法: bash main-test-xht.sh [文件夹名称]

set -e
set -o pipefail
START_TRAINING="true"  # 控制是否开始训练，设置为 "false" 可以跳过训练部分

# ===================== 1. 核心路径配置 =====================
RUNS_ROOT="/root/autodl-tmp/docker-monitor/runs"
TRAIN_BASE_DIR="/root/autodl-tmp/uniad/Bench2DriveZoo"

# 硬编码的训练程序与配置
TRAIN_SCRIPT_REL="adzoo/uniad/uniad_dist_train.sh"
TRAIN_CONFIG_REL="adzoo/uniad/configs/stage2_e2e/base_e2e_b2d.py"
TRAIN_GPU_NUM="1"

# 环境与监控脚本
CONDA_BIN="/root/miniconda3/bin/conda"
CONDA_ENV="b2d_zoo"
MONITOR_SCRIPT="/root/autodl-tmp/docker-monitor/monitor_resources.sh"

# ===================== 2. 参数与目录处理 =====================
SUB_DIR_NAME="${1}"
if [ -z "$SUB_DIR_NAME" ]; then
    echo "错误: 请提供文件夹名称。用法: bash $0 train_1"
    exit 1
fi

RUN_DIR="${RUNS_ROOT}/${SUB_DIR_NAME}"
mkdir -p "$RUN_DIR"

MONITOR_LOG="${RUN_DIR}/monitor.log"
DATA_FILE="${RUN_DIR}/resource_usage.csv"
TRAIN_LOG="${RUN_DIR}/train.log"

# 计算训练脚本的绝对路径
TRAIN_SCRIPT_ABS="${TRAIN_BASE_DIR}/${TRAIN_SCRIPT_REL}"

# ===================== 3. 权限检查与修复 =====================
echo -e "  检查脚本执行权限..."

# 3.1 监控脚本权限
if [ ! -x "$MONITOR_SCRIPT" ]; then
    echo "   修复监控脚本权限: $MONITOR_SCRIPT"
    chmod +x "$MONITOR_SCRIPT"
fi

# 3.2 训练脚本权限
if [ ! -x "$TRAIN_SCRIPT_ABS" ]; then
    echo "   修复训练脚本权限: $TRAIN_SCRIPT_ABS"
    chmod +x "$TRAIN_SCRIPT_ABS"
fi
echo "   权限检查完成"

# ===================== 4. 环境激活与监控启动 =====================
echo -e "\n 输出目录: $RUN_DIR"
source "$("$CONDA_BIN" info --base)/bin/activate" "$CONDA_ENV"

# 强制清理之前的监控进程
pkill -9 -f "$(basename "$MONITOR_SCRIPT")" || true

export RESOURCE_OUTPUT_FILE="$DATA_FILE"
nohup "$MONITOR_SCRIPT" > "$MONITOR_LOG" 2>&1 &
MONITOR_PID=$!
sleep 2

# ===================== 5. 执行 UniAD 训练 =====================

# 确保即使跳过训练，也不会报错
if [ "$START_TRAINING" == "true" ]; then
    echo " 启动训练+资源监控..."
    cd "$TRAIN_BASE_DIR"

    # 允许训练脚本报错而不中断主脚本，以便执行后续的清理
    set +e
    ./"$TRAIN_SCRIPT_REL" "$TRAIN_CONFIG_REL" "$TRAIN_GPU_NUM" 2>&1 | tee "$TRAIN_LOG"
    TRAIN_EXIT_CODE=${PIPESTATUS[0]}
    set -e
else
    # 如果跳过训练，直接设置 TRAIN_EXIT_CODE 为 0，避免报错
    TRAIN_EXIT_CODE=0
    #要监控2s
    sleep 6
fi

# ===================== 6. 停止监控与善后 =====================
echo -e "\n 训练结束，正在关闭监控..."
kill "$MONITOR_PID" 2>/dev/null || true
pkill -9 -f "$(basename "$MONITOR_SCRIPT")" || true

echo -e "========================================"
echo " 任务统计"
echo " 结果目录: $RUN_DIR"
if [ $TRAIN_EXIT_CODE -eq 0 ]; then
    echo " 状态: 训练执行成功"
else
    echo " 状态: 训练任务异常 (Exit Code: $TRAIN_EXIT_CODE)"
fi
echo "========================================"
