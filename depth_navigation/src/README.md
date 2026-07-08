# MiDaS Depth C++ Node — Source Code

## 文件说明

| 文件 | 说明 |
|------|------|
| `midas_depth_node.cpp` | C++ 推理主程序（~1000行），4线程异步架构 |
| `CMakeLists.txt` | CMake 构建配置（ROS2 ament_cmake） |
| `package.xml` | ROS2 包描述文件 |

## 编译

```bash
# 在 ROS2 workspace 中
cd /path/to/ws
cp -r src/midas_depth_node.cpp src/  # 放到你的 midas_nav/src/ 下
colcon build --packages-select midas_nav
```

## 依赖

- ROS2 Humble
- OpenCV 4.x
- hb_dnn (D-Robotics BPU SDK)
- hbplugin (hobot_dnn ROS2 plugin)

## 架构

4 线程异步流水线：
1. **Capture thread** — 相机采集 → 共享帧缓冲区
2. **Inference thread** — BGR→NV12 → BPU 推理 → 深度后处理 → PointCloud2
3. **Image pub thread** — 异步发布压缩/缩放图像
4. **ROS2 spin thread** — 处理回调和服务

## 编译产物

预编译二进制: `midas_depth_cpp`（部署包根目录，aarch64）
