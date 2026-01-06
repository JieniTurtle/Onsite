#!/bin/bash
# monitor_render.sh - 专门适配 Carla 渲染流程的资源监控脚本
# 用法: bash monitor_render.sh [渲染参数/RENDER_ID] [文件夹名称]
# 示例: bash monitor_render.sh 1 render_2

set -e
set -o pipefail

# ===================== 1. 核心路径配置 =====================
# 监控结果存放的根目录
RUNS_ROOT="/root/autodl-tmp/docker-monitor/runs"

# 渲染任务脚本 (你提供的那个 main.sh)
RENDER_SCRIPT="/root/autodl-tmp/carla_data_collect/scripts/main.sh"

# 环境与资源监控脚本
CONDA_BIN="/root/miniconda3/bin/conda"
CONDA_ENV="b2d_zoo"
MONITOR_SCRIPT="/root/autodl-tmp/docker-monitor/monitor_resources.sh"

# ===================== 2. 参数处理 =====================
RENDER_ID="${1}" 
SUB_DIR_NAME="${2}"

if [ -z "$RENDER_ID" ] || [ -z "$SUB_DIR_NAME" ]; then
    echo "❌ 错误: 参数缺失。"
    echo "用法: bash $0 [RENDER_ID] [文件夹名称]"
    echo "示例: bash $0 1 render_2"
    exit 1
fi

# 拼接完整的输出路径
RUN_DIR="${RUNS_ROOT}/${SUB_DIR_NAME}"
mkdir -p "$RUN_DIR"

MONITOR_LOG="${RUN_DIR}/monitor.log"
DATA_FILE="${RUN_DIR}/resource_usage.csv"
RENDER_LOG="${RUN_DIR}/render.log"

# ===================== 3. 权限检查与清理 =====================
echo -e "🛡️  权限检查与环境清理..."

chmod +x "$MONITOR_SCRIPT" "$RENDER_SCRIPT"

# 强制清理残留的监控进程和可能卡死的 Carla 进程
pkill -9 -f "$(basename "$MONITOR_SCRIPT")" || true
# 注意：清理 Carla 进程需要小心，这里仅清理属于当前用户的残留
pkill -9 -f CarlaUE4 || true
pkill -9 -f scenario_runner || true

# ===================== 4. 环境激活与监控启动 =====================
echo -e "\n📂 输出目录: $RUN_DIR"
# 激活环境用于运行监控脚本
source "$("$CONDA_BIN" info --base)/bin/activate" "$CONDA_ENV"

export RESOURCE_OUTPUT_FILE="$DATA_FILE"
nohup "$MONITOR_SCRIPT" > "$MONITOR_LOG" 2>&1 &
MONITOR_PID=$!
sleep 2

# ===================== 5. 执行渲染任务 (Carla 依赖链) =====================
echo "🚀 启动 Carla 渲染任务 (RENDER_ID: $RENDER_ID)..."

# 切换到渲染脚本目录
RENDER_BASE_DIR=$(dirname "$RENDER_SCRIPT")
cd "$RENDER_BASE_DIR"

# 运行你提供的 main.sh
# 它内部会处理 Carla、ScenarioRunner 和数据收集的启动与终止
set +e
bash "$RENDER_SCRIPT" render "$RENDER_ID" 2>&1 | tee "$RENDER_LOG"
RENDER_EXIT_CODE=${PIPESTATUS[0]}
set -e

# ===================== 6. 停止监控与善后 =====================
echo -e "\n🛑 渲染主流程结束，正在关闭监控..."
kill "$MONITOR_PID" 2>/dev/null || true
pkill -9 -f "$(basename "$MONITOR_SCRIPT")" || true

echo -e "========================================"
echo "📊 任务统计"
echo "📂 结果目录: $RUN_DIR"
if [ $RENDER_EXIT_CODE -eq 0 ]; then
    echo "✅ 状态: 渲染及数据收集成功"
else
    echo "❌ 状态: 过程异常退出 (Exit Code: $RENDER_EXIT_CODE)"
fi
echo "========================================"

touch "${RUN_DIR}/DONE"