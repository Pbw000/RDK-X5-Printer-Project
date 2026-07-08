#!/bin/bash
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "开始部署..."

cd /path/to/printer_backend
log "进入项目目录: $(pwd)"

log "开始编译 (release)..."
cargo build --release
log "编译完成"

log "复制二进制文件到部署目录..."
cp /path/to/printer_backend/target/release/printer_backend /path/to/printer_deploy/printer_backend
log "部署完成 ✓"