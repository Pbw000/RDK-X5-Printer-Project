#!/bin/bash
# 一键清空所有打印任务
# 用法: sudo bash ~/clear-print-queue.sh

set -e

echo "[1/4] 停止 CUPS 服务..."
systemctl stop cups 2>/dev/null
systemctl stop cups-browsed 2>/dev/null
sleep 1

echo "[2/4] 清空 spool 和缓存..."
rm -rf /var/spool/cups/*
rm -rf /var/spool/cups/tmp/*
truncate -s0 /var/cache/cups/job.cache 2>/dev/null
truncate -s0 /var/cache/cups/job.cache.O 2>/dev/null
rm -f /var/cache/cups/cups-browsed-options-*
rm -f /var/cache/cups/*.data
rm -f /var/cache/cups/*.strings

echo "[3/4] 重启 CUPS 服务..."
systemctl start cups
systemctl start cups-browsed
sleep 2

echo "[4/4] 验证结果..."
echo "--- 打印机状态 ---"
lpstat -p 2>/dev/null || echo "  无打印机"
echo "--- 打印队列 ---"
lpstat -o 2>/dev/null || echo "  队列为空"
