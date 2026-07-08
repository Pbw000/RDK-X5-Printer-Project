#!/bin/bash
# 查看所有打印任务状态
# 用法: bash ~/Desktop/printer_backend/check-print-queue.sh

echo "========== 打机状态 =========="
lpstat -p 2>/dev/null || echo "  无打印机"

echo ""
echo "========== 待处理任务 =========="
lpstat -W not-completed -o 2>/dev/null || echo "  队列为空"

echo ""
echo "========== 已完成任务 =========="
lpstat -W completed -o 2>/dev/null || echo "  无历史记录"

echo ""
echo "========== 默认打印机 =========="
lpstat -d 2>/dev/null || echo "  未设置"

echo ""
echo "========== 打印机详情 =========="
lpstat -v 2>/dev/null || echo "  无"
