# 🤖 Mobile Printing Robot System

[简体中文](./README_cn.md) | English

A full-stack mobile printing robot system built on the **RDK X5** development board. The robot autonomously navigates to designated locations to receive and execute print jobs. Covers low-level motor control, depth-perception obstacle avoidance, navigation scheduling backend, and a Flutter mobile app.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Sub-Projects](#sub-projects)
  - [printer_backend — Scheduling Backend](#printer_backend--scheduling-backend)
  - [motor_controller — Motor Controller](#motor_controller--motor-controller)
  - [depth_navigation — Depth Perception Navigation](#depth_navigation--depth-perception-navigation)
  - [mobile_app — Mobile App](#mobile_app--mobile-app)
- [Hardware Requirements](#hardware-requirements)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [License](#license)

---

## Overview

This project implements a complete mobile printing robot system with the following core capabilities:

- **Autonomous Navigation**: ROS 2 Nav2-based path planning and navigation with multi-destination scheduling
- **Depth Perception**: MiDaS model running on RDK X5 BPU for real-time inference and point-cloud obstacle avoidance
- **Motor Control**: Differential drive chassis, serial communication, odometry, and autonomous exploration mode
- **Print Scheduling**: File upload, queue management, priority sorting, and CUPS print execution
- **Mobile Control**: Flutter app for file submission, status monitoring, and AI assistant interaction

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       Mobile App (Flutter)                       │
│  File Upload · Location Select · Task Monitor · AI · Live Map   │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP/SSE
┌──────────────────────────▼──────────────────────────────────────┐
│                   Printer Backend (Rust/Axum)                    │
│  REST API · SSE Push · Task Scheduling · Nav2 · CUPS · Map      │
└───────┬──────────────────────────────────────────┬──────────────┘
        │ ROS 2                                    │ ROS 2
┌───────▼────────────────┐          ┌──────────────▼──────────────┐
│ Motor Controller (Rust) │          │ Depth Navigation (C++/ROS2) │
│ Serial Comms · Diff     │          │ MiDaS BPU Inference · Point │
│ Drive · Odom · Explore  │          │ Cloud · Ground Calibration  │
└────────────────────────┘          └─────────────────────────────┘
        │ Serial                                     │ USB Camera
   ┌────▼─────┐                                 ┌────▼─────┐
   │Motor Board│                                 │RGB Camera│
   └──────────┘                                 └──────────┘
```

---

## Sub-Projects

### printer_backend — Scheduling Backend

**Stack:** Rust + Axum + Tokio + r2r (ROS 2) + CUPS

The backend service is the system's scheduling center, running on RDK X5, providing REST APIs and SSE real-time push.

| Module | Function |
|--------|----------|
| `handlers/` | REST API route handlers (file upload, job submission, location list, navigation status, etc.) |
| `scheduler/` | Print task scheduler, manages print queue and execution flow |
| `services/` | File storage and job management business logic |
| `ros_nav.rs` | ROS 2 Nav2 navigation interface (path planning, navigation execution, odometry, map retrieval) |
| `auth_server/` | Batch completion confirmation service (separate port 3001) |
| `static/` | Web dashboard frontend (plain HTML/JS/CSS) |

**Key API Endpoints:**

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/upload` | POST | File upload (multipart) |
| `/api/locations` | GET | List preset navigation destinations |
| `/api/jobs` | POST | Submit print jobs |
| `/api/files/{id}/status` | GET | Query file processing status |
| `/api/navigation/status` | GET | Get navigation status |
| `/api/printer/status` | GET | Get printer status |
| `/api/printer/position` | GET | Get robot's current position |
| `/api/map` | GET | Get SLAM map snapshot |
| `/api/events` | GET | SSE real-time event stream |

**Build & Run:**

```bash
cargo build --release
./target/release/printer_backend
```

Configuration files are in the `config/` directory:
- `app.json` — Port, bind address, printer name
- `dest.json` — Navigation destination list

---

### motor_controller — Motor Controller

**Stack:** Rust + Tokio + r2r (ROS 2) + tokio-serial

Low-level motor control and communication module. Communicates with the motor driver board via serial port, providing differential drive and odometry functionality.

| Module | Function |
|--------|----------|
| `model.rs` | Serial frame protocol (Aho-Corasick frame detection + Postcard serialization) |
| `ros_adoptor.rs` | Differential drive model, odometry estimation, ROS 2 Twist/Odom/TF bridge |
| `explorer.rs` | VFH autonomous exploration (Vector Field Histogram obstacle avoidance + coverage grid + stuck recovery) |
| `planner/` | Path planning module |
| `back/web/` | Web monitoring panel (real-time motor status, IMU data visualization) |

**Operating Modes:**

- **Normal Mode:** Subscribes to ROS 2 `/cmd_vel`, executes velocity commands, publishes `/odom` and TF
- **Explore Mode (`--explore`):** LiDAR-based VFH autonomous exploration with automatic obstacle avoidance and coverage

```bash
# Normal mode
cargo run --release

# Explore mode
cargo run --release -- --explore
```

---

### depth_navigation — Depth Perception Navigation

**Stack:** C++ + ROS 2 Humble + OpenCV + D-Robotics BPU SDK (hb_dnn)

Depth perception module based on the MiDaS Small model, performing real-time inference on RDK X5 BPU and generating obstacle point clouds for Nav2 costmap consumption.

**Key Features:**

- **4-Thread Async Architecture:** Capture → Inference → Image Publish → ROS Callback, non-blocking
- **Ground-Plane Calibration:** Uses camera mounting height and pixel row angles to map inverse depth to real-world metric distances
- **Temporal EMA Smoothing:** Reduces frame-to-frame depth jitter
- **Foxglove Compatible:** Synchronized CameraInfo + raw image + point cloud publishing for 3D visualization

**Published ROS 2 Topics:**

| Topic | Type | Description |
|-------|------|-------------|
| `/midas/obstacles_cloud` | PointCloud2 | Obstacle point cloud (Nav2 costmap input) |
| `/camera_info` | CameraInfo | Camera intrinsics (Foxglove 3D view) |
| `/camera/image_raw` | Image | Thumbnail image (Foxglove camera view) |

**Build:**

```bash
cd /path/to/ros2_ws
colcon build --packages-select midas_nav
source install/setup.bash
```

**Run:**

```bash
# Launch depth node + Nav2
bash start_midas_alt.sh

# Launch depth node + Foxglove bridge
bash start_midas_foxglove.sh
```

---

### mobile_app — Mobile App

**Stack:** Flutter + Dart + Provider + flutter_rust_bridge

Flutter mobile application providing a complete print task management interface.

| Module | Function |
|--------|----------|
| `screens/` | Main screen, home, task queue, status monitor, AI assistant |
| `services/` | API communication, SSE event stream, local database, printer state management |
| `agent/` | AI assistant (OpenAI-compatible streaming + tool calling) |
| `models/` | Data models (locations, files, jobs) |
| `widgets/` | Map widget, file preview, location selector |
| `src/rust/` | Rust FFI bridge (flutter_rust_bridge auto-generated) |
| `audio/` | Audio service |

**Highlights:**

- 📍 Map Visualization — Shows robot position and target locations
- 📤 File Upload — Progress bar and file preview support
- 🔄 Real-time Status — SSE-driven live updates
- 🤖 AI Assistant — Natural language print task management
- 🎨 Liquid Glass UI — Modern interface design

---

## Hardware Requirements

| Component | Specification |
|-----------|---------------|
| **Main Board** | D-Robotics RDK X5 |
| **Camera** | USB RGB camera (V4L2, MJPEG format) |
| **Motor Driver** | Serial differential drive board (115200 baud) |
| **LiDAR** | 2D LiDAR (ROS 2 `/scan` topic) |
| **Printer** | CUPS-compatible printer |
| **Chassis** | Differential drive chassis (2 wheels + caster) |

**Software Dependencies:**

- ROS 2 Humble
- D-Robotics BPU SDK (hb_dnn)
- Nav2 (navigation)
- CUPS (printing)
- Flutter SDK (mobile app compilation)

---

## Quick Start

### 1. Build the Backend

```bash
cd printer_backend
cargo build --release
```

### 2. Configure Destinations

Edit `printer_backend/config/dest.json` to set navigation target coordinates.

### 3. Launch Depth Perception

```bash
cd depth_navigation
bash start_midas_alt.sh
```

### 4. Start Motor Controller

```bash
cd motor_controller
cargo run --release
```

### 5. Start Backend Service

```bash
cd printer_backend
./target/release/printer_backend
```

### 6. Run Mobile App

```bash
cd mobile_app
flutter run
```

---

## Configuration

### printer_backend/config/app.json

```json
{
    "port": 3000,
    "bind_all": true,
    "printer_name": "Your_Printer_Name"
}
```

### depth_navigation/config/midas_nav_params.yaml

Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `model_path` | — | Path to MiDaS model file |
| `camera_id` | 0 | USB camera device ID |
| `fov_h` / `fov_v` | 73.7° / 55.3° | Camera field of view |
| `camera_z` | 0.72 m | Camera mounting height |
| `min_depth` / `max_depth` | 0.25 / 1.2 m | Detection depth range |
| `point_stride` | 8 | Point cloud sparsity factor |

---

## License

This project is licensed under the Apache-2.0 License.
