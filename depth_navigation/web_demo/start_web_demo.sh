#!/bin/bash
# MiDaS Web Demo (C++) — Startup Script
# Usage:
#   bash start_web_demo.sh              # Start (port 8080)
#   bash start_web_demo.sh --port 9090  # Custom port
#   bash start_web_demo.sh --camera 1   # Force /dev/video1
#   bash start_web_demo.sh --stop       # Stop

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="/tmp/midas_web_demo.pid"
PORT=8080
CAMERA_DEV=""   # empty = auto-detect

# --- Camera auto-detection ---
detect_camera_dev() {
    local best_dev=""
    local best_fmt=0
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        local fmt_count=$(v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null | grep -c "\[.*\]:")
        if [ "$fmt_count" -gt "$best_fmt" ]; then
            best_fmt=$fmt_count
            best_dev="$dev"
        fi
    done
    if [ -n "$best_dev" ]; then
        echo "$best_dev"
    else
        echo "/dev/video0"  # fallback
    fi
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop)
            if [ -f "$PID_FILE" ]; then
                kill $(cat "$PID_FILE") 2>/dev/null
                rm -f "$PID_FILE"
                echo "MiDaS Web Demo stopped."
            else
                echo "Not running."
            fi
            exit 0
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --camera)
            CAMERA_DEV="/dev/video$2"
            shift 2
            ;;
        --camera=*)
            CAMERA_DEV="/dev/video${1#--camera=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Stop any existing instance
[ -f "$PID_FILE" ] && kill $(cat "$PID_FILE") 2>/dev/null && sleep 1

# Build if needed
if [ ! -f "$SCRIPT_DIR/midas_web_demo" ]; then
    echo "Building..."
    make -C "$SCRIPT_DIR" || exit 1
fi

# Auto-detect camera if not specified
if [ -z "$CAMERA_DEV" ]; then
    CAMERA_DEV=$(detect_camera_dev)
    echo "  Camera: auto-detected $CAMERA_DEV"
else
    echo "  Camera: manual $CAMERA_DEV"
fi

# Get IP
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$IP" ] && IP="localhost"

echo "=========================================="
echo "  MiDaS Web Demo (C++)"
echo "=========================================="
echo "  Local:  http://localhost:$PORT"
echo "  LAN:    http://$IP:$PORT"
echo "  Camera: $CAMERA_DEV"
echo "  Stop:   bash $0 --stop"
echo "=========================================="

cd "$SCRIPT_DIR"
nohup ./midas_web_demo --port "$PORT" --camera "$CAMERA_DEV" > /tmp/midas_web_demo.log 2>&1 &
echo $! > "$PID_FILE"
sleep 1

if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "  ✓ Running (PID $(cat $PID_FILE))"
    echo "  Log: /tmp/midas_web_demo.log"
else
    echo "  ✗ Failed to start!"
    tail -20 /tmp/midas_web_demo.log
    exit 1
fi
