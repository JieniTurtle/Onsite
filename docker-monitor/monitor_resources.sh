#!/bin/bash
# AutoDL容器资源监控

# ========== 配置项 ==========
DATA_FILE="${RESOURCE_OUTPUT_FILE:-resource_usage.csv}"
INTERVAL=2  # 采集间隔（秒）
MAX_RUN_SECONDS=3600  # 最大运行时长（1小时，防止无限跑）
EXIT_FLAG=0           # 优雅退出标志

# ========== 信号捕获：处理终止信号 ==========
trap 'EXIT_FLAG=1' SIGTERM SIGINT SIGQUIT

# ========== 初始化CSV（覆盖旧文件） ==========
echo "timestamp,training_time_seconds,cpu_usage_total_seconds,gpu_utilization_total(%),gpu_memory_total_mb,memory_usage_total_mb" > "$DATA_FILE"

echo "🔍 开始AutoDL实例资源总量监控..."
echo "📁 数据文件: $DATA_FILE"
echo "⏱ 采集间隔: ${INTERVAL}s | 最大运行时长: ${MAX_RUN_SECONDS}s"

# ========== 依赖检查 ==========
if ! command -v bc &> /dev/null; then
    echo "❌ 缺少bc命令，正在自动安装..."
    apt-get update >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 安装bc失败，请手动执行: apt-get update && apt-get install -y bc"
        exit 1
    fi
fi

# ========== 读取容器CPU ==========
get_cpu_jiffies() {
    # cgroup v1 cpuacct.usage 是纳秒级总CPU耗时（所有核心）
    if [ -f "/sys/fs/cgroup/cpu,cpuacct/cpuacct.usage" ]; then
        CPU_USAGE_NS=$(cat /sys/fs/cgroup/cpu,cpuacct/cpuacct.usage 2>/dev/null || echo 0)
        # 纳秒转秒（核心修正：1秒=10^9纳秒，而非jiffies）
        echo "scale=4; $CPU_USAGE_NS / 1000000000" | bc
    else
        # 降级到宿主机：读取/proc/stat计算CPU总jiffies（1 jiffy=0.01秒）
        cpu_line=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "cpu 0 0 0 0 0 0 0 0 0 0")
        user=$(echo $cpu_line | awk '{print $2}')
        nice=$(echo $cpu_line | awk '{print $3}')
        system=$(echo $cpu_line | awk '{print $4}')
        idle=$(echo $cpu_line | awk '{print $5}')
        irq=$(echo $cpu_line | awk '{print $7}')
        softirq=$(echo $cpu_line | awk '{print $8}')
        steal=$(echo $cpu_line | awk '{print $9}')
        total_jiffies=$((user + nice + system + idle + irq + softirq + steal))
        echo "scale=4; $total_jiffies / 100" | bc  # jiffies转秒
    fi
}

# ========== 读取容器内存 ==========
get_container_mem() {
    if [ -f "/sys/fs/cgroup/memory/memory.usage_in_bytes" ]; then
        MEM_USAGE_B=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        # 防止数值溢出，限制最大值
        if [ $MEM_USAGE_B -gt $((1024 * 1024 * 1024 * 1024)) ]; then
            MEM_USAGE_B=$((1024 * 1024 * 1024 * 1024))
        fi
        echo $((MEM_USAGE_B / 1024 / 1024))  # 字节转MB
    else
        # 降级到宿主机：读取已用内存（MB）
        free -m 2>/dev/null | grep Mem | awk '{print $3}' || echo "0"
    fi
}

# ========== 读取GPU信息 ==========
get_gpu_total() {
    # 无nvidia-smi直接返回0
    if ! command -v nvidia-smi &> /dev/null; then
        echo "0.0,0"
        return
    fi

    # 处理CUDA_VISIBLE_DEVICES（多卡/空值）
    GPU_IDS=${CUDA_VISIBLE_DEVICES:-all}
    if [ "$GPU_IDS" = "all" ]; then
        GPU_IDS=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi

    # 累加所有GPU的利用率和显存
    total_util=0.0
    total_mem=0
    gpu_count=0
    for id in $(echo $GPU_IDS | tr ',' ' '); do
        gpu_info=$(nvidia-smi --id=$id --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null)
        if [ -n "$gpu_info" ]; then
            util=$(echo $gpu_info | awk -F', ' '{print $1}')
            mem=$(echo $gpu_info | awk -F', ' '{print $2}')
            # 容错：非数字值置0
            util=$(echo "$util" | grep -E '^[0-9.]+$' || echo 0)
            mem=$(echo "$mem" | grep -E '^[0-9]+$' || echo 0)
            total_util=$(echo "scale=1; $total_util + $util" | bc)
            total_mem=$((total_mem + mem))
            gpu_count=$((gpu_count + 1))
        fi
    done

    # 计算平均利用率（多卡场景）
    if [ $gpu_count -gt 0 ]; then
        avg_util=$(echo "scale=1; $total_util / $gpu_count" | bc)
    else
        avg_util=0.0
    fi
    printf "%.1f,%d" "$avg_util" "$total_mem"
}

# ========== 初始化参数（容错修复） ==========
TRAINING_START=$(date +%s)
LAST_CPU_SECONDS=$(get_cpu_jiffies)
TOTAL_CPU_SECONDS="0.0000"

# 容器内存限额（容错：处理无限制场景）
if [ -f "/sys/fs/cgroup/memory/memory.limit_in_bytes" ]; then
    MEM_LIMIT_B=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
    if [ $MEM_LIMIT_B -eq $((1 << 63)) ] || [ $MEM_LIMIT_B -gt $((1024 * 1024 * 1024 * 1024)) ]; then
        MEM_LIMIT_GB="无限制"
    else
        MEM_LIMIT_GB=$((MEM_LIMIT_B / 1024 / 1024 / 1024))
    fi
else
    MEM_LIMIT_GB="未知"
fi

# 宿主机总内存
HOST_MEM_TOTAL_MB=$(free -m 2>/dev/null | grep Mem | awk '{print $2}' || echo 0)
HOST_MEM_TOTAL_GB=$((HOST_MEM_TOTAL_MB / 1024))

echo "✅ 训练开始时间: $(date -d @$TRAINING_START '+%Y-%m-%d %H:%M:%S')"
echo "✅ 容器内存限额: $MEM_LIMIT_GB GB"
echo "✅ 宿主机总内存: $HOST_MEM_TOTAL_GB GB"
sleep $INTERVAL

# ========== 主监控循环（添加退出条件） ==========
COUNTER=0
while [ $EXIT_FLAG -eq 0 ]; do
    COUNTER=$((COUNTER + 1))
    CURRENT_TIME=$(date +%s)
    TIMESTAMP_READABLE=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 1. 训练累计用时（秒）
    TRAINING_TIME_SECONDS=$((CURRENT_TIME - TRAINING_START))
    
    # 2. CPU累计使用时长（秒，修复差值计算）
    CURRENT_CPU_SECONDS=$(get_cpu_jiffies)
    CPU_DIFF_SECONDS=$(echo "scale=4; $CURRENT_CPU_SECONDS - $LAST_CPU_SECONDS" | bc)
    # 防止负数（进程重启/时间回拨）
    if (( $(echo "$CPU_DIFF_SECONDS < 0" | bc -l) )); then
        CPU_DIFF_SECONDS="0.0000"
    fi
    TOTAL_CPU_SECONDS=$(echo "scale=4; $TOTAL_CPU_SECONDS + $CPU_DIFF_SECONDS" | bc)
    
    # 3. GPU信息（利用率%，显存MB）
    GPU_TOTAL_INFO=$(get_gpu_total)
    GPU_UTIL_TOTAL=$(echo "$GPU_TOTAL_INFO" | cut -d',' -f1)
    GPU_MEM_TOTAL=$(echo "$GPU_TOTAL_INFO" | cut -d',' -f2)
    
    # 4. 容器已用内存（MB）
    MEMORY_USED_MB=$(get_container_mem)
    
    # 5. 写入CSV（强制刷盘，避免缓存）
    echo "$TIMESTAMP_READABLE,$TRAINING_TIME_SECONDS,$TOTAL_CPU_SECONDS,$GPU_UTIL_TOTAL,$GPU_MEM_TOTAL,$MEMORY_USED_MB" >> "$DATA_FILE"
    sync "$DATA_FILE"  # 强制将缓存写入磁盘
    
    # 6. 调试输出（每5次打印一次）
    if [ $((COUNTER % 5)) -eq 0 ]; then
        echo "[$TIMESTAMP_READABLE] 训练:${TRAINING_TIME_SECONDS}s | CPU累计:${TOTAL_CPU_SECONDS}s | GPU:${GPU_UTIL_TOTAL}% ${GPU_MEM_TOTAL}MB | 容器内存:${MEMORY_USED_MB}MB"
    fi
    
    # 7. 更新上次CPU值
    LAST_CPU_SECONDS=$CURRENT_CPU_SECONDS
    
    # 8. 检查退出条件（信号/超时）
    if [ $EXIT_FLAG -eq 1 ] || [ $TRAINING_TIME_SECONDS -ge $MAX_RUN_SECONDS ]; then
        echo -e "\n📤 监控脚本退出（信号触发/超时）"
        break
    fi
    
    sleep $INTERVAL
done

# ========== 脚本结束清理 ==========
echo "✅ 监控脚本正常结束，最终数据已写入: $DATA_FILE"
echo "📊 数据总行数: $(wc -l < "$DATA_FILE")"
exit 0