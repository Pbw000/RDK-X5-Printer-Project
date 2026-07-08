# 🤖 移动打印机器人系统

[English](./README.md) | 简体中文

基于 **RDK X5** 开发板的移动打印机器人全栈系统。机器人自主导航到指定位置，接收并执行打印任务。涵盖底层电机控制、深度感知避障、导航调度后端和 Flutter 移动端 App。

---

## 📋 目录

- [系统概述](#系统概述)
- [系统架构](#系统架构)
- [子项目说明](#子项目说明)
  - [printer_backend — 调度后端](#printer_backend--调度后端)
  - [motor_controller — 电机控制器](#motor_controller--电机控制器)
  - [depth_navigation — 深度感知导航](#depth_navigation--深度感知导航)
  - [mobile_app — 移动端 App](#mobile_app--移动端-app)
- [硬件需求](#硬件需求)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [许可证](#许可证)

---

## 系统概述

本项目实现了一个完整的移动打印机器人系统，核心功能包括：

- **自主导航**：基于 ROS 2 Nav2 的路径规划与导航，支持多目标点调度
- **深度感知**：MiDaS 模型在 RDK X5 BPU 上实时推理，生成点云避障
- **电机控制**：差速驱动底盘，串口通信，里程计推算，支持自主探索模式
- **打印调度**：文件上传、队列管理、优先级排序、CUPS 打印执行
- **移动端控制**：Flutter App 实现文件提交、状态监控、AI 助手交互

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                       Mobile App (Flutter)                      │
│  文件上传 · 位置选择 · 任务监控 · AI 助手 · 实时地图            │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP/SSE
┌──────────────────────────▼──────────────────────────────────────┐
│                   Printer Backend (Rust/Axum)                    │
│  REST API · SSE推送 · 任务调度 · Nav2导航 · CUPS打印 · 地图     │
└───────┬──────────────────────────────────────────┬──────────────┘
        │ ROS 2                                    │ ROS 2
┌───────▼────────────────┐          ┌──────────────▼──────────────┐
│ Motor Controller (Rust) │          │ Depth Navigation (C++/ROS2) │
│ 串口通信 · 差速驱动     │          │ MiDaS BPU推理 · 点云发布    │
│ 里程计 · 自主探索       │          │ 地面标定 · 避障costmap      │
└────────────────────────┘          └─────────────────────────────┘
        │ 串口                                     │ USB 相机
   ┌────▼────┐                                ┌─────▼──────┐
   │电机驱动板│                                │ RGB Camera │
   └─────────┘                                └────────────┘
```

---

## 子项目说明

### printer_backend — 调度后端

**技术栈：** Rust + Axum + Tokio + r2r (ROS 2) + CUPS

后端服务是整个系统的调度中心，运行在 RDK X5 上，提供 REST API 和 SSE 实时推送。

| 模块 | 功能 |
|------|------|
| `handlers/` | REST API 路由处理（文件上传、任务提交、位置列表、导航状态等） |
| `scheduler/` | 打印任务调度器，管理打印队列和执行流程 |
| `services/` | 文件存储、任务管理业务逻辑 |
| `ros_nav.rs` | ROS 2 Nav2 导航接口（路径规划、导航执行、里程计、地图获取） |
| `auth_server/` | 批次完成确认服务（独立端口 3001） |
| `static/` | Web 仪表盘前端（纯 HTML/JS/CSS） |

**主要 API：**

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/health` | GET | 健康检查 |
| `/api/upload` | POST | 文件上传（multipart） |
| `/api/locations` | GET | 获取预设目标位置列表 |
| `/api/jobs` | POST | 提交打印任务 |
| `/api/files/{id}/status` | GET | 查询文件处理状态 |
| `/api/navigation/status` | GET | 获取导航状态 |
| `/api/printer/status` | GET | 获取打印机状态 |
| `/api/printer/position` | GET | 获取机器人当前位置 |
| `/api/map` | GET | 获取 SLAM 地图快照 |
| `/api/events` | GET | SSE 实时事件流 |

**编译与运行：**

```bash
cargo build --release
./target/release/printer_backend
```

配置文件位于 `config/` 目录：
- `app.json` — 端口、绑定地址、打印机名称
- `dest.json` — 导航目标位置列表

---

### motor_controller — 电机控制器

**技术栈：** Rust + Tokio + r2r (ROS 2) + tokio-serial

底层电机控制与通信模块，通过串口与电机驱动板交互，提供差速驱动和里程计功能。

| 模块 | 功能 |
|------|------|
| `model.rs` | 串口帧协议（Aho-Corasick 帧检测 + Postcard 序列化） |
| `ros_adoptor.rs` | 差速驱动模型、里程计推算、ROS 2 Twist/Odom/TF 桥接 |
| `explorer.rs` | VFH 自主探索算法（向量场直方图避障 + 覆盖栅格 + 卡住恢复） |
| `planner/` | 路径规划模块 |
| `back/web/` | Web 监控面板（实时电机状态、IMU 数据可视化） |

**运行模式：**

- **正常模式：** 订阅 ROS 2 `/cmd_vel`，执行速度指令，发布 `/odom` 和 TF
- **探索模式 (`--explore`)：** 基于激光雷达的 VFH 自主探索，自动避障和覆盖

```bash
# 正常模式
cargo run --release

# 探索模式
cargo run --release -- --explore
```

---

### depth_navigation — 深度感知导航

**技术栈：** C++ + ROS 2 Humble + OpenCV + D-Robotics BPU SDK (hb_dnn)

基于 MiDaS Small 模型的深度感知模块，在 RDK X5 BPU 上实时推理，生成障碍物点云供 Nav2 costmap 使用。

**核心特性：**

- **4 线程异步架构：** 采集 → 推理 → 图像发布 → ROS 回调，互不阻塞
- **地面平面标定：** 利用相机安装高度和像素行角度，将逆深度映射到真实米制距离
- **时序 EMA 平滑：** 减少帧间深度抖动
- **Foxglove 兼容：** 同步发布 CameraInfo + 原始图像 + 点云，支持 3D 可视化

**发布的 ROS 2 话题：**

| 话题 | 类型 | 说明 |
|------|------|------|
| `/midas/obstacles_cloud` | PointCloud2 | 障碍物点云（Nav2 costmap 输入） |
| `/camera_info` | CameraInfo | 相机内参（Foxglove 3D 视图） |
| `/camera/image_raw` | Image | 缩略图（Foxglove 相机视图） |

**编译：**

```bash
cd /path/to/ros2_ws
colcon build --packages-select midas_nav
source install/setup.bash
```

**运行：**

```bash
# 启动深度节点 + Nav2
bash start_midas_alt.sh

# 启动深度节点 + Foxglove 桥接
bash start_midas_foxglove.sh
```

---

### mobile_app — 移动端 App

**技术栈：** Flutter + Dart + Provider + flutter_rust_bridge

Flutter 移动端应用，提供完整的打印任务管理界面。

| 模块 | 功能 |
|------|------|
| `screens/` | 主界面、首页、任务队列、状态监控、AI 助手 |
| `services/` | API 通信、SSE 事件流、本地数据库、打印状态管理 |
| `agent/` | AI 助手（OpenAI 兼容流式对话 + 工具调用） |
| `models/` | 数据模型（位置、文件、任务） |
| `widgets/` | 地图组件、文件预览、位置选择器 |
| `src/rust/` | Rust FFI 桥接（flutter_rust_bridge 自动生成） |
| `audio/` | 音频服务 |

**功能亮点：**

- 📍 地图可视化 — 显示机器人位置和目标点
- 📤 文件上传 — 支持进度条和文件预览
- 🔄 实时状态 — SSE 驱动的实时更新
- 🤖 AI 助手 — 自然语言管理打印任务
- 🎨 Liquid Glass UI — 现代化界面设计

---

## 硬件需求

| 组件 | 规格 |
|------|------|
| **主控板** | D-Robotics RDK X5 |
| **相机** | USB RGB 摄像头（V4L2，MJPEG 格式） |
| **电机驱动** | 串口通信差速驱动板（115200 baud） |
| **激光雷达** | 2D LiDAR（ROS 2 `/scan` 话题） |
| **打印机** | CUPS 兼容打印机 |
| **底盘** | 差速驱动底盘（两轮 + 万向轮） |

**软件依赖：**

- ROS 2 Humble
- D-Robotics BPU SDK (hb_dnn)
- Nav2 (导航)
- CUPS (打印)
- Flutter SDK (移动端编译)

---

## 快速开始

### 1. 编译后端

```bash
cd printer_backend
cargo build --release
```

### 2. 配置目标位置

编辑 `printer_backend/config/dest.json`，设置导航目标点坐标。

### 3. 启动深度感知

```bash
cd depth_navigation
bash start_midas_alt.sh
```

### 4. 启动电机控制

```bash
cd motor_controller
cargo run --release
```

### 5. 启动后端服务

```bash
cd printer_backend
./target/release/printer_backend
```

### 6. 运行移动端

```bash
cd mobile_app
flutter run
```

---

## 配置说明

### printer_backend/config/app.json

```json
{
    "port": 3000,
    "bind_all": true,
    "printer_name": "Your_Printer_Name"
}
```

### depth_navigation/config/midas_nav_params.yaml

关键参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `model_path` | — | MiDaS 模型文件路径 |
| `camera_id` | 0 | USB 相机设备 ID |
| `fov_h` / `fov_v` | 73.7° / 55.3° | 相机视场角 |
| `camera_z` | 0.72 m | 相机安装高度 |
| `min_depth` / `max_depth` | 0.25 / 1.2 m | 检测深度范围 |
| `point_stride` | 8 | 点云稀疏因子 |

---

## 许可证

本项目采用 Apache-2.0 许可证。
