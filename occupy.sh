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

# 获取CPU核心数
CPU_CORES=$(nproc)
TARGET_CORES=${1:-$CPU_CORES}

echo -e "${GREEN}=== CPU负载控制脚本 ===${NC}"
echo -e "${YELLOW}可用CPU核心数: ${CPU_CORES}${NC}"
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
    local core_id=$1
    echo -e "${GREEN}启动核心 ${core_id} 的负载生成器${NC}"
    
    while true; do
        # 工作50毫秒 (50% 负载)
        timeout 0.05s yes > /dev/null 2>&1
        
        # 休眠50毫秒 (让CPU休息)
        sleep 0.05
    done
}

# 为每个CPU核心启动负载生成器
for ((i=0; i<$TARGET_CORES; i++)); do
    generate_load $i &
done

# 显示进程信息
echo ""
echo -e "${YELLOW}负载进程已启动，PID:${NC}"
jobs -p

# 保持脚本运行
wait

