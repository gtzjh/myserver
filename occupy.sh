#!/bin/bash

# occupy.sh - 让CPU保持在50%左右的负载
# 使用方法: ./occupy.sh [CPU核心数]
# 例如: ./occupy.sh 2  (使用2个CPU核心)
# 默认使用所有可用的CPU核心

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取允许使用的CPU核心列表
get_allowed_cpu_list() {
    # 尝试从 /proc/self/status 获取允许的CPU列表
    if [ -f /proc/self/status ]; then
        local cpu_list=$(grep "Cpus_allowed_list:" /proc/self/status 2>/dev/null | awk '{print $2}')
        if [ -n "$cpu_list" ]; then
            echo "$cpu_list"
            return
        fi
    fi
    
    # 如果无法获取，使用默认范围
    echo "0-$(($(nproc)-1))"
}

# 将CPU列表转换为数组（支持范围格式如 0-3,6-7）
parse_cpu_list() {
    local cpu_list=$1
    local result=()
    
    IFS=',' read -ra RANGES <<< "$cpu_list"
    for range in "${RANGES[@]}"; do
        if [[ $range =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # 范围格式: 0-3
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            for ((i=start; i<=end; i++)); do
                result+=($i)
            done
        else
            # 单个数字
            result+=($range)
        fi
    done
    
    echo "${result[@]}"
}

# 获取实际可用的CPU核心数（考虑容器限制）
get_available_cpus() {
    local nproc_cores=$(nproc)
    local quota_cores=$nproc_cores
    
    # 检查 cgroup v2 (新版本)
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local cpu_max=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)
        local quota=$(echo $cpu_max | awk '{print $1}')
        local period=$(echo $cpu_max | awk '{print $2}')
        
        if [ "$quota" != "max" ] && [ -n "$period" ] && [ "$period" != "0" ]; then
            quota_cores=$((quota / period))
            [ $quota_cores -eq 0 ] && quota_cores=1
        fi
    # 检查 cgroup v1 (旧版本)
    elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        local period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
        
        if [ "$quota" != "-1" ] && [ -n "$period" ] && [ "$period" != "0" ]; then
            quota_cores=$((quota / period))
            [ $quota_cores -eq 0 ] && quota_cores=1
        fi
    fi
    
    # 同时考虑 CPU affinity 的限制
    local allowed_list=$(get_allowed_cpu_list)
    local allowed_array=($(parse_cpu_list "$allowed_list"))
    local affinity_cores=${#allowed_array[@]}
    
    # 返回最小值（考虑配额和亲和性）
    local min_cores=$nproc_cores
    [ $quota_cores -lt $min_cores ] && min_cores=$quota_cores
    [ $affinity_cores -lt $min_cores ] && min_cores=$affinity_cores
    
    echo $min_cores
}

# 获取允许的CPU核心列表和数组
ALLOWED_CPU_LIST=$(get_allowed_cpu_list)
ALLOWED_CPU_ARRAY=($(parse_cpu_list "$ALLOWED_CPU_LIST"))
CPU_CORES=$(get_available_cpus)
TARGET_CORES=${1:-$CPU_CORES}

echo -e "${GREEN}=== CPU负载控制脚本 ===${NC}"
echo -e "${YELLOW}物理CPU核心数: $(nproc)${NC}"
echo -e "${YELLOW}允许的CPU核心: ${ALLOWED_CPU_LIST}${NC}"
echo -e "${YELLOW}可用CPU核心数: ${CPU_CORES}${NC}"
if [ $CPU_CORES -lt $(nproc) ]; then
    echo -e "${YELLOW}(检测到容器CPU限制)${NC}"
fi
echo -e "${YELLOW}将使用核心数: ${TARGET_CORES}${NC}"
echo -e "${YELLOW}目标负载: 50%${NC}"
echo ""
echo -e "${GREEN}按 Ctrl+C 停止${NC}"
echo ""

# 清理函数
cleanup() {
    echo -e "\n${RED}正在停止所有负载进程...${NC}"
    kill $(jobs -p) 2>/dev/null
    wait 2>/dev/null
    echo -e "${GREEN}已停止${NC}"
    exit 0
}

# 捕获中断信号
trap cleanup SIGINT SIGTERM

# 负载生成函数
generate_load() {
    local index=$1
    local cpu_core=$2
    
    # 如果系统支持 taskset，则绑定到特定CPU核心
    if command -v taskset > /dev/null 2>&1; then
        echo -e "${GREEN}启动负载生成器 #${index}，绑定到CPU核心 ${cpu_core}${NC}"
        taskset -c $cpu_core bash -c '
            while true; do
                timeout 0.05s yes > /dev/null 2>&1
                sleep 0.05
            done
        '
    else
        echo -e "${GREEN}启动负载生成器 #${index} (无CPU绑定)${NC}"
        while true; do
            timeout 0.05s yes > /dev/null 2>&1
            sleep 0.05
        done
    fi
}

# 为每个CPU核心启动负载生成器
for ((i=0; i<$TARGET_CORES; i++)); do
    # 从允许的CPU核心列表中选择对应的核心
    local cpu_core=${ALLOWED_CPU_ARRAY[$i]}
    generate_load $i $cpu_core &
done

# 显示进程信息
echo ""
echo -e "${YELLOW}负载进程已启动，PID:${NC}"
jobs -p

# 保持脚本运行
wait

