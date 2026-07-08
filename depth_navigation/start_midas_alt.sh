#!/bin/bash
# =============================================================================
# MiDaS Alt Navigation — Based on working nav/ + MiDaS obstacle avoidance
# =============================================================================
# Strategy: LiDAR = primary (clearing + marking), MiDaS = supplementary (marking only)
# All Nav2 parameters identical to working nav/ except midas_cloud added to costmap.
# =============================================================================
# Usage:
#   bash start_midas_alt.sh              # Start everything
#   bash start_midas_alt.sh --no-rviz    # Skip RViz
#   bash start_midas_alt.sh --no-lidar   # Skip LiDAR (MiDaS only)
#   bash start_midas_alt.sh --no-midas   # Skip MiDaS (pure LiDAR nav)
#   bash start_midas_alt.sh --stop       # Stop all
#   bash start_midas_alt.sh --status     # Check status
# =============================================================================

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_DIR="/tmp/midas_alt_pids_$(whoami)"

# --- Configuration ---
LIDAR_PORT="/dev/ttyUSB0"
BAUDRATE=230400
PRODUCT_NAME="LDLiDAR_LD06"
FRAME_ID="base_laser"
MAP_FILE="$DEPLOY_DIR/slam/maps/slam_map.yaml"
NAV2_PARAMS="$SCRIPT_DIR/config/nav2_params.yaml"
MIDAS_PARAMS="$SCRIPT_DIR/config/midas_nav_params.yaml"
ROS_RESOLVER="$DEPLOY_DIR/ros_resolver"
RVIZ_CONFIG="$SCRIPT_DIR/rviz/rviz.rviz"
MODEL_PATH="$SCRIPT_DIR/models/midas_small_384_v2.bin"

# --- Camera auto-detection ---
detect_camera() {
    local best_id=-1
    local best_fmt=0
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        local idx=$(basename "$dev" | sed 's/video//')
        # Count supported capture formats — real cameras have >0, metadata nodes have 0
        local fmt_count=$(v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null | grep -c "\[.*\]:")
        if [ "$fmt_count" -gt "$best_fmt" ]; then
            best_fmt=$fmt_count
            best_id=$idx
        fi
    done
    if [ "$best_id" -ge 0 ]; then
        echo "$best_id"
    else
        echo "0"  # fallback
    fi
}

# MiDaS C++ node from midas_nav install
MIDAS_INSTALL_DIR="$DEPLOY_DIR/midas_nav/install"

# --- Parse arguments ---
STOP_ONLY=false
STATUS_ONLY=false
NO_RVIZ=false
WITH_LIDAR=true
WITH_MIDAS=true
CAMERA_ID=""   # empty = auto-detect
shift_next=false

for arg in "$@"; do
    case "$arg" in
        --stop)      STOP_ONLY=true ;;
        --status)    STATUS_ONLY=true ;;
        --no-rviz)   NO_RVIZ=true ;;
        --no-lidar)  WITH_LIDAR=false ;;
        --no-midas)  WITH_MIDAS=false ;;
        --camera)
            shift_next=true ;;
        --camera=*)
            CAMERA_ID="${arg#--camera=}" ;;
        --help|-h)
            echo "Usage: bash $0 [OPTIONS]"
            echo "  (no args)    Start LiDAR + MiDaS + Nav2 + RViz"
            echo "  --no-lidar   Skip LiDAR (MiDaS only mode)"
            echo "  --no-midas   Skip MiDaS (pure LiDAR nav — same as nav/)"
            echo "  --no-rviz    Skip RViz"
            echo "  --camera=N   Force camera device index (default: auto-detect)"
            echo "  --camera N   Force camera device index (space-separated)"
            echo "  --stop       Stop all"
            echo "  --status     Check status"
            exit 0 ;;
        *)
            # If previous arg was --camera, this is the value
            if [ "$shift_next" = true ]; then
                CAMERA_ID="$arg"
                shift_next=false
            fi
            ;;
    esac
done

# --- Cleanup ---
cleanup_all() {
    echo "Stopping MiDaS-Alt navigation..."
    pkill -f ros_resolver 2>/dev/null || true
    pkill -f ldlidar_ros2_node 2>/dev/null || true
    pkill -f midas_depth_cpp 2>/dev/null || true
    pkill -f nav2_bringup 2>/dev/null || true
    pkill -f component_container_isolated 2>/dev/null || true
    pkill -f component_container 2>/dev/null || true
    pkill -f static_transform_publisher 2>/dev/null || true
    pkill -f lifecycle_manager 2>/dev/null || true
    pkill -f controller_server 2>/dev/null || true
    pkill -f planner_server 2>/dev/null || true
    pkill -f behavior_server 2>/dev/null || true
    pkill -f bt_navigator 2>/dev/null || true
    pkill -f velocity_smoother 2>/dev/null || true
    pkill -f waypoint_follower 2>/dev/null || true
    pkill -f smoother_server 2>/dev/null || true
    pkill -f amcl 2>/dev/null || true
    pkill -f map_server 2>/dev/null || true
    pkill -f rviz2 2>/dev/null || true
    sleep 2
    pkill -9 -f ros_resolver 2>/dev/null || true
    pkill -9 -f ldlidar_ros2_node 2>/dev/null || true
    pkill -9 -f midas_depth_cpp 2>/dev/null || true
    pkill -9 -f component_container 2>/dev/null || true
    pkill -9 -f static_transform_publisher 2>/dev/null || true
    pkill -9 -f rviz2 2>/dev/null || true
    rm -rf "$PID_DIR"
    echo "Navigation stopped."
}

check_status() {
    echo "============================================"
    echo "  MiDaS-Alt Navigation Status"
    echo "============================================"
    [ ! -d "$PID_DIR" ] && echo "  Not running." && return
    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        name=$(basename "$pidfile" .pid)
        pid=$(cat "$pidfile" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ✓ $name (PID $pid)"
        else
            echo "  ✗ $name (PID $pid) — DEAD"
        fi
    done
    echo "  Logs: $PID_DIR/*.log"
    source /opt/ros/humble/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42
    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
    echo "  Topics:"
    ros2 topic list 2>/dev/null | grep -E "(midas|costmap|scan|odom)" | while read t; do echo "    $t"; done
}

$STOP_ONLY && cleanup_all && exit 0
$STATUS_ONLY && check_status && exit 0

cleanup_all
sleep 1
mkdir -p "$PID_DIR"

# --- ROS2 Environment ---
source /opt/ros/humble/setup.bash
[ -f /opt/tros/humble/setup.bash ] && source /opt/tros/humble/setup.bash
[ -f /path/to/ros2_slam_ws/install/setup.bash ] && source /path/to/ros2_slam_ws/install/setup.bash
[ -f "$MIDAS_INSTALL_DIR/setup.bash" ] && source "$MIDAS_INSTALL_DIR/setup.bash"
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=42   # 隔离局域网内 PIPER 机械臂的 DDS 幽灵节点

# Common env for subshells
ROS_ENV="source /opt/ros/humble/setup.bash && source /opt/tros/humble/setup.bash 2>/dev/null; [ -f /path/to/ros2_slam_ws/install/setup.bash ] && source /path/to/ros2_slam_ws/install/setup.bash; [ -f $MIDAS_INSTALL_DIR/setup.bash ] && source $MIDAS_INSTALL_DIR/setup.bash; export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp; export ROS_DOMAIN_ID=42"

# --- Display setup ---
if [ -z "$DISPLAY" ]; then
    for d in /tmp/.X11-unix/X*; do
        num=$(basename "$d" | sed 's/X//')
        if DISPLAY=":$num" xdpyinfo >/dev/null 2>&1; then
            export DISPLAY=":$num"; break
        fi
    done
    [ -z "$DISPLAY" ] && export DISPLAY=:1
    export XAUTHORITY=/path/to/.Xauthority
fi
xhost +SI:localuser:root 2>/dev/null || true

echo "============================================"
echo "  MiDaS-Alt Navigation System"
echo "  (nav/ base + MiDaS supplementary)"
echo "============================================"
echo "  Map: $MAP_FILE"
echo "  LiDAR: $WITH_LIDAR"
echo "  MiDaS: $WITH_MIDAS"
echo "  RViz: $(if $NO_RVIZ; then echo no; else echo yes; fi)"
echo "  DISPLAY: $DISPLAY"
echo ""

# ---- Auto-detect camera ----
if $WITH_MIDAS; then
    if [ -z "$CAMERA_ID" ]; then
        CAMERA_ID=$(detect_camera)
        echo "  Camera: auto-detected /dev/video$CAMERA_ID"
    else
        echo "  Camera: manual override /dev/video$CAMERA_ID"
    fi
fi
echo ""
STEP=0

# ---- 1. ros_resolver ----
STEP=$((STEP+1))
echo "[$STEP/7] Starting ros_resolver..."
LD_LIBRARY_PATH=/opt/ros/humble/lib:$LD_LIBRARY_PATH "$ROS_RESOLVER" > "$PID_DIR/ros_resolver.log" 2>&1 &
echo $! > "$PID_DIR/ros_resolver.pid"
sleep 3
if ! kill -0 $(cat "$PID_DIR/ros_resolver.pid") 2>/dev/null; then
    echo "  ERROR: ros_resolver failed!"
    cat "$PID_DIR/ros_resolver.log" | tail -10
    exit 1
fi
echo "  OK (PID $(cat $PID_DIR/ros_resolver.pid))"

# ---- 2. LiDAR ----
if $WITH_LIDAR; then
    STEP=$((STEP+1))
    echo "[$STEP/7] Starting LiDAR..."
    nohup bash -c "$ROS_ENV && ros2 run ldlidar_ros2 ldlidar_ros2_node \
        --ros-args \
        -p product_name:=$PRODUCT_NAME \
        -p laser_scan_topic_name:=scan \
        -p point_cloud_2d_topic_name:=pointcloud2d \
        -p frame_id:=$FRAME_ID \
        -p port_name:=$LIDAR_PORT \
        -p serial_baudrate:=$BAUDRATE \
        -p laser_scan_dir:=true \
        -p enable_angle_crop_func:=true \
        -p angle_crop_min:=120.0 \
        -p angle_crop_max:=240.0 \
        -p range_min:=0.20 \
        -p range_max:=12.0" > "$PID_DIR/ldlidar.log" 2>&1 &
    echo $! > "$PID_DIR/ldlidar.pid"
    sleep 3
    echo "  OK (PID $(cat $PID_DIR/ldlidar.pid))"
fi

# ---- 3. Static TF ----
STEP=$((STEP+1))
echo "[$STEP/7] Static TF..."
# base_link -> base_laser (LiDAR mount)
nohup bash -c "$ROS_ENV && exec ros2 run tf2_ros static_transform_publisher \
    -- -0.01 0 0.1 3.1415926 0 0 base_link $FRAME_ID" > "$PID_DIR/tf_lidar.log" 2>&1 &
echo $! > "$PID_DIR/tf_lidar.pid"
sleep 0.5

# base_link -> camera_link (Camera mount)
nohup bash -c "$ROS_ENV && exec ros2 run tf2_ros static_transform_publisher \
    -- 0.11 0 0.72 0 0 0 base_link camera_link" > "$PID_DIR/tf_camera.log" 2>&1 &
echo $! > "$PID_DIR/tf_camera.pid"
sleep 0.5

# map -> odom (static fallback — replaced by AMCL when LiDAR available)
nohup bash -c "$ROS_ENV && exec ros2 run tf2_ros static_transform_publisher \
    -- 0 0 0 0 0 0 map odom" > "$PID_DIR/tf_map.log" 2>&1 &
echo $! > "$PID_DIR/tf_map.pid"
sleep 1
echo "  OK: map→odom, base_link→base_laser, base_link→camera_link"

# ---- 4. MiDaS Depth Node ----
if $WITH_MIDAS; then
    STEP=$((STEP+1))
    echo "[$STEP/7] Starting MiDaS Depth Node (C++)..."
    [ ! -f "$MODEL_PATH" ] && { echo "  ERROR: Model not found: $MODEL_PATH"; exit 1; }
    nohup bash -c "$ROS_ENV && ros2 run midas_nav midas_depth_cpp \
        --ros-args --params-file $MIDAS_PARAMS \
        -p camera_id:=$CAMERA_ID" > "$PID_DIR/midas_depth.log" 2>&1 &
    echo $! > "$PID_DIR/midas_depth.pid"
    sleep 3
    if kill -0 $(cat "$PID_DIR/midas_depth.pid") 2>/dev/null; then
        echo "  OK (PID $(cat $PID_DIR/midas_depth.pid))"
    else
        echo "  WARN: MiDaS failed — continuing without depth"
        echo "  Log:"; tail -5 "$PID_DIR/midas_depth.log"
    fi
fi

# ---- 5. Nav2 ----
STEP=$((STEP+1))
echo "[$STEP/7] Starting Nav2..."
nohup bash -c "$ROS_ENV && ros2 launch nav2_bringup bringup_launch.py \
    use_sim_time:=false \
    slam:=False \
    map:=$MAP_FILE \
    params_file:=$NAV2_PARAMS \
    autostart:=true \
    use_composition:=True" > "$PID_DIR/nav2.log" 2>&1 &
echo $! > "$PID_DIR/nav2.pid"
echo "  Nav2 starting (takes ~10s)..."
sleep 10
echo "  OK (PID $(cat $PID_DIR/nav2.pid))"

# ---- 6. RViz2 ----
if ! $NO_RVIZ; then
    STEP=$((STEP+1))
    echo "[$STEP/7] Starting RViz2..."
    nohup bash -c "export DISPLAY=$DISPLAY && export XAUTHORITY=$XAUTHORITY && $ROS_ENV && ros2 run rviz2 rviz2 -d $RVIZ_CONFIG" > "$PID_DIR/rviz.log" 2>&1 &
    echo $! > "$PID_DIR/rviz.pid"

    # Wait for RViz and maximize
    for i in $(seq 1 20); do
        RVIZ_WIN=$(xdotool search --name "RViz" 2>/dev/null | head -1)
        if [ -n "$RVIZ_WIN" ]; then
            sleep 1
            xdotool windowactivate "$RVIZ_WIN" 2>/dev/null
            xdotool windowsize "$RVIZ_WIN" 100% 100% 2>/dev/null
            xdotool key F11 2>/dev/null
            echo "  RViz2 fullscreen OK"
            break
        fi
        sleep 1
    done
fi

# ---- Status ----
echo ""
echo "============================================"
echo "  MiDaS-Alt Navigation Running"
echo "============================================"
for pidfile in "$PID_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    name=$(basename "$pidfile" .pid)
    pid=$(cat "$pidfile")
    if kill -0 $pid 2>/dev/null; then
        echo "  ✓ $name (PID $pid)"
    else
        echo "  ✗ $name (PID $pid) — DEAD"
    fi
done
echo ""
echo "  Logs: $PID_DIR/*.log"
echo "  Stop: bash $0 --stop"
echo "  Status: bash $0 --status"
echo "============================================"
