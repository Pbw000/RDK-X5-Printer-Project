#!/bin/bash
# =============================================================================
# MiDaS Alt Navigation — Foxglove Edition (no RViz, with Foxglove Bridge)
# =============================================================================
# Same as start_midas_alt.sh but replaces RViz with foxglove_bridge.
# Connect from Foxglove Studio on your PC:
#   ws://<robot-ip>:8765
# =============================================================================
# Usage:
#   bash start_midas_foxglove.sh              # Start everything + Foxglove bridge
#   bash start_midas_foxglove.sh --no-lidar   # Skip LiDAR (MiDaS only)
#   bash start_midas_foxglove.sh --no-midas   # Skip MiDaS (pure LiDAR nav)
#   bash start_midas_foxglove.sh --port 9000  # Custom bridge port
#   bash start_midas_foxglove.sh --stop       # Stop all
#   bash start_midas_foxglove.sh --status     # Check status
# =============================================================================

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_DIR="/tmp/midas_alt_pids_$(whoami)"

# --- Configuration ---
LIDAR_PORT="/dev/ttyUSB0"
BAUDRATE=230400
PRODUCT_NAME="LDLiDAR_LD06"
FRAME_ID="base_laser"
MAP_FILE="$DEPLOY_DIR/maps/final.yaml"
NAV2_PARAMS="$SCRIPT_DIR/config/nav2_params.yaml"
MIDAS_PARAMS="$SCRIPT_DIR/config/midas_nav_params.yaml"
ROS_RESOLVER="$DEPLOY_DIR/ros_resolver"
MODEL_PATH="$SCRIPT_DIR/models/midas_small_384_v2.bin"
FOXGLOVE_PORT=8765

# MiDaS C++ node from midas_nav install
MIDAS_INSTALL_DIR="$DEPLOY_DIR/midas_nav/install"

# --- Parse arguments ---
STOP_ONLY=false
STATUS_ONLY=false
WITH_LIDAR=true
WITH_MIDAS=true

for arg in "$@"; do
    case "$arg" in
        --stop)      STOP_ONLY=true ;;
        --status)    STATUS_ONLY=true ;;
        --no-lidar)  WITH_LIDAR=false ;;
        --no-midas)  WITH_MIDAS=false ;;
        --port)      shift; FOXGLOVE_PORT="$1" ;;
        --port=*)    FOXGLOVE_PORT="${arg#--port=}" ;;
        --help|-h)
            echo "Usage: bash $0 [OPTIONS]"
            echo "  (no args)    Start LiDAR + MiDaS + Nav2 + Foxglove Bridge"
            echo "  --no-lidar   Skip LiDAR (MiDaS only mode)"
            echo "  --no-midas   Skip MiDaS (pure LiDAR nav — same as nav/)"
            echo "  --port N     Foxglove bridge port (default: 8765)"
            echo "  --stop       Stop all"
            echo "  --status     Check status"
            exit 0 ;;
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
    pkill -f foxglove_bridge 2>/dev/null || true
    sleep 2
    pkill -9 -f ros_resolver 2>/dev/null || true
    pkill -9 -f ldlidar_ros2_node 2>/dev/null || true
    pkill -9 -f midas_depth_cpp 2>/dev/null || true
    pkill -9 -f component_container 2>/dev/null || true
    pkill -9 -f static_transform_publisher 2>/dev/null || true
    pkill -9 -f foxglove_bridge 2>/dev/null || true
    rm -rf "$PID_DIR"
    echo "Navigation stopped."
}

check_status() {
    echo "============================================"
    echo "  MiDaS-Alt Navigation Status (Foxglove)"
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
    # Check if foxglove bridge port is listening
    if ss -tlnp 2>/dev/null | grep -q ":$FOXGLOVE_PORT"; then
        IP=$(hostname -I | awk '{print $1}')
        echo ""
        echo "  Foxglove Bridge: ws://$IP:$FOXGLOVE_PORT"
    fi
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

ROBOT_IP=$(hostname -I | awk '{print $1}')

echo "============================================"
echo "  MiDaS-Alt Navigation System (Foxglove)"
echo "  (nav/ base + MiDaS supplementary)"
echo "============================================"
echo "  Map: $MAP_FILE"
echo "  LiDAR: $WITH_LIDAR"
echo "  MiDaS: $WITH_MIDAS"
echo "  Foxglove: ws://$ROBOT_IP:$FOXGLOVE_PORT"
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

# odom -> base_link (static — no wheel odometry on this robot)
nohup bash -c "$ROS_ENV && exec ros2 run tf2_ros static_transform_publisher \
    -- 0 0 0 0 0 0 odom base_link" > "$PID_DIR/tf_odom.log" 2>&1 &
echo $! > "$PID_DIR/tf_odom.pid"
sleep 0.5

# map -> odom (static fallback — replaced by AMCL when LiDAR available)
nohup bash -c "$ROS_ENV && exec ros2 run tf2_ros static_transform_publisher \
    -- 0 0 0 0 0 0 map odom" > "$PID_DIR/tf_map.log" 2>&1 &
echo $! > "$PID_DIR/tf_map.pid"
sleep 1
echo "  OK: map→odom→base_link, base_link→base_laser, base_link→camera_link"

# ---- 4. MiDaS Depth Node ----
if $WITH_MIDAS; then
    STEP=$((STEP+1))
    echo "[$STEP/7] Starting MiDaS Depth Node (C++)..."
    [ ! -f "$MODEL_PATH" ] && { echo "  ERROR: Model not found: $MODEL_PATH"; exit 1; }
    nohup bash -c "$ROS_ENV && ros2 run midas_nav midas_depth_cpp \
        --ros-args --params-file $MIDAS_PARAMS" > "$PID_DIR/midas_depth.log" 2>&1 &
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

# ---- 6. Foxglove Bridge ----
# NOTE: Exclude /particle_cloud and /*/transition_event — Nav2 composition mode
# publishes these from multiple components with different QoS, causing
# "duplicate channels with mismatched schema" errors in Foxglove Studio.
STEP=$((STEP+1))
echo "[$STEP/7] Starting Foxglove Bridge (port $FOXGLOVE_PORT)..."
nohup bash -c "$ROS_ENV && ros2 launch foxglove_bridge foxglove_bridge_launch.xml \
    port:=$FOXGLOVE_PORT \
    address:=0.0.0.0 \
    topic_whitelist:=\"['^(?!.*transition_event|.*particle_cloud).*']\" \
    capabilities:=\"[clientPublish,parameters,services,connectionGraph,assets]\"" > "$PID_DIR/foxglove.log" 2>&1 &
echo $! > "$PID_DIR/foxglove.pid"
sleep 3
if kill -0 $(cat "$PID_DIR/foxglove.pid") 2>/dev/null; then
    echo "  OK (PID $(cat $PID_DIR/foxglove.pid))"
else
    echo "  WARN: Foxglove bridge failed — check $PID_DIR/foxglove.log"
    tail -5 "$PID_DIR/foxglove.log"
fi

# ---- Status ----
echo ""
echo "============================================"
echo "  MiDaS-Alt Navigation Running (Foxglove)"
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
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Foxglove Studio Connection:            │"
echo "  │  ws://$ROBOT_IP:$FOXGLOVE_PORT                    │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  Open Foxglove Studio → Open connection → paste URL above"
echo "  Logs: $PID_DIR/*.log"
echo "  Stop: bash $0 --stop"
echo "  Status: bash $0 --status"
echo "============================================"
