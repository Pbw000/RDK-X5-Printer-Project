// Copyright (c) 2026, D-Robotics RDK X5
// MiDaS Depth Node - C++ implementation for BPU inference
//
// This node captures camera frames, runs MiDaS Small model on BPU,
// and publishes depth point clouds for obstacle avoidance.

#include <chrono>
#include <memory>
#include <string>
#include <vector>
#include <cmath>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>

#include "rclcpp/rclcpp.hpp"
#include "sensor_msgs/msg/point_cloud2.hpp"
#include "sensor_msgs/msg/point_field.hpp"
#include "sensor_msgs/msg/camera_info.hpp"
#include "sensor_msgs/msg/image.hpp"
#include "std_msgs/msg/header.hpp"

#include "dnn_node/dnn_node.h"
#include "opencv2/opencv.hpp"
#include "dnn/hb_sys.h"

namespace midas_nav {

using namespace hobot::dnn_node;
using namespace std::chrono_literals;

// Camera intrinsics structure
struct CameraIntrinsics {
  double fx, fy;  // focal lengths
  double cx, cy;  // principal point
  int width, height;
  
  void compute_from_fov(double fov_h_deg, double fov_v_deg, int w, int h) {
    width = w;
    height = h;
    double fov_h_rad = fov_h_deg * M_PI / 180.0;
    double fov_v_rad = fov_v_deg * M_PI / 180.0;
    fx = w / (2.0 * std::tan(fov_h_rad / 2.0));
    fy = h / (2.0 * std::tan(fov_v_rad / 2.0));
    cx = w / 2.0;
    cy = h / 2.0;
  }
};

// 3D point structure
struct Point3D {
  float x, y, z;
};

// Custom NV12 input with automatic BPU memory management
class ManagedNV12Input : public NV12PyramidInput {
public:
  hbSysMem y_mem;
  hbSysMem uv_mem;
  bool allocated = false;
  
  ~ManagedNV12Input() override {
    if (allocated) {
      hbSysFreeMem(&y_mem);
      hbSysFreeMem(&uv_mem);
    }
  }
};

class MidasDepthNode : public DnnNode {
public:
  MidasDepthNode() : DnnNode("midas_depth_cpp") {
    // Declare parameters
    this->declare_parameter("model_path", "/path/to/models/midas_small_384_v2.bin");
    this->declare_parameter("camera_id", 0);
    this->declare_parameter("camera_width", 640);
    this->declare_parameter("camera_height", 480);
    this->declare_parameter("fps", 30.0);
    
    this->declare_parameter("fov_h", 73.7);
    this->declare_parameter("fov_v", 55.3);
    this->declare_parameter("camera_x", 0.11);
    this->declare_parameter("camera_y", 0.0);
    this->declare_parameter("camera_z", 0.72);
    this->declare_parameter("camera_pitch", 0.0);
    
    this->declare_parameter("min_depth", 0.3);
    this->declare_parameter("max_depth", 2.3);
    this->declare_parameter("ground_height_threshold", 0.25);
    this->declare_parameter("point_stride", 6);
    this->declare_parameter("publish_rate", 20.0);
    
    // CameraInfo / raw image publishing for Foxglove 3D view
    this->declare_parameter("publish_camera_info", true);
    this->declare_parameter("publish_raw_image", true);
    this->declare_parameter("camera_info_topic", "/camera_info");
    this->declare_parameter("image_topic", "/camera/image_raw");
    
    // Load parameters
    model_path_ = this->get_parameter("model_path").as_string();
    camera_id_ = this->get_parameter("camera_id").as_int();
    camera_width_ = this->get_parameter("camera_width").as_int();
    camera_height_ = this->get_parameter("camera_height").as_int();
    fps_ = this->get_parameter("fps").as_double();
    
    fov_h_ = this->get_parameter("fov_h").as_double();
    fov_v_ = this->get_parameter("fov_v").as_double();
    camera_x_ = this->get_parameter("camera_x").as_double();
    camera_y_ = this->get_parameter("camera_y").as_double();
    camera_z_ = this->get_parameter("camera_z").as_double();
    camera_pitch_ = this->get_parameter("camera_pitch").as_double();
    
    min_depth_ = this->get_parameter("min_depth").as_double();
    max_depth_ = this->get_parameter("max_depth").as_double();
    ground_height_threshold_ = this->get_parameter("ground_height_threshold").as_double();
    point_stride_ = this->get_parameter("point_stride").as_int();
    publish_rate_ = this->get_parameter("publish_rate").as_double();
    
    publish_camera_info_ = this->get_parameter("publish_camera_info").as_bool();
    publish_raw_image_ = this->get_parameter("publish_raw_image").as_bool();
    camera_info_topic_ = this->get_parameter("camera_info_topic").as_string();
    image_topic_ = this->get_parameter("image_topic").as_string();
    
    // Compute camera intrinsics
    intrinsics_.compute_from_fov(fov_h_, fov_v_, camera_width_, camera_height_);
    
    // Precompute rotation matrix
    precompute_transforms();
    
    // Publisher — low-latency QoS: depth=2, RELIABLE (compatible with Nav2 costmap)
    auto low_latency_qos = rclcpp::QoS(2).reliable().durability_volatile();
    
    pointcloud_pub_ = this->create_publisher<sensor_msgs::msg::PointCloud2>(
      "/midas/obstacles_cloud", low_latency_qos);
    
    // CameraInfo publisher (for Foxglove 3D view)
    if (publish_camera_info_) {
      camera_info_pub_ = this->create_publisher<sensor_msgs::msg::CameraInfo>(
        camera_info_topic_, low_latency_qos);
      
      // Pre-build CameraInfo message (static, only stamp changes)
      camera_info_msg_ = sensor_msgs::msg::CameraInfo();
      camera_info_msg_.height = camera_height_;
      camera_info_msg_.width = camera_width_;
      camera_info_msg_.distortion_model = "plumb_bob";
      camera_info_msg_.d = {0.0, 0.0, 0.0, 0.0, 0.0};
      camera_info_msg_.k = {
        intrinsics_.fx, 0.0, intrinsics_.cx,
        0.0, intrinsics_.fy, intrinsics_.cy,
        0.0, 0.0, 1.0
      };
      camera_info_msg_.r = {
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
      };
      camera_info_msg_.p = {
        intrinsics_.fx, 0.0, intrinsics_.cx, 0.0,
        0.0, intrinsics_.fy, intrinsics_.cy, 0.0,
        0.0, 0.0, 1.0, 0.0
      };
      camera_info_msg_.header.frame_id = "camera_link";
      
      RCLCPP_INFO(this->get_logger(), "CameraInfo: publishing to %s (%dx%d, fx=%.1f fy=%.1f)",
                  camera_info_topic_.c_str(), camera_width_, camera_height_,
                  intrinsics_.fx, intrinsics_.fy);
    }
    
    // Raw image publisher (for Foxglove camera view)
    if (publish_raw_image_) {
      image_pub_ = this->create_publisher<sensor_msgs::msg::Image>(
        image_topic_, low_latency_qos);
      RCLCPP_INFO(this->get_logger(), "Raw image: publishing to %s", image_topic_.c_str());
    }
    
    RCLCPP_INFO(this->get_logger(), "MiDaS Depth Node (C++) initialized");
    RCLCPP_INFO(this->get_logger(), "Model: %s", model_path_.c_str());
    RCLCPP_INFO(this->get_logger(), "Camera: %dx%d @ %.1f FPS", 
                camera_width_, camera_height_, fps_);
    RCLCPP_INFO(this->get_logger(), "FOV: %.1f° x %.1f°", fov_h_, fov_v_);
    RCLCPP_INFO(this->get_logger(), "Depth range: %.1f - %.1f m", min_depth_, max_depth_);
  }
  
  ~MidasDepthNode() override {
    running_ = false;
    frame_cv_.notify_all();  // Wake up inference thread if waiting
    image_pub_cv_.notify_all();  // Wake up image publish thread
    if (image_pub_thread_.joinable()) {
      image_pub_thread_.join();
    }
    if (inference_thread_.joinable()) {
      inference_thread_.join();
    }
    if (camera_thread_.joinable()) {
      camera_thread_.join();
    }
    if (camera_.isOpened()) {
      camera_.release();
    }
  }
  
  int start() {
    // Initialize DNN node
    if (Init() != 0) {
      RCLCPP_ERROR(this->get_logger(), "Failed to initialize DNN node");
      return -1;
    }
    
    // Open camera
    if (!open_camera()) {
      RCLCPP_ERROR(this->get_logger(), "Failed to open camera");
      return -1;
    }
    
    // Start producer (capture), consumer (inference), and image publisher threads
    running_ = true;
    camera_thread_ = std::thread(&MidasDepthNode::capture_loop, this);
    inference_thread_ = std::thread(&MidasDepthNode::inference_loop, this);
    if (publish_raw_image_ && image_pub_) {
      image_pub_thread_ = std::thread(&MidasDepthNode::image_publish_loop, this);
    }
    
    RCLCPP_INFO(this->get_logger(), "MiDaS Depth Node started (3 threads: capture + inference + image_pub)");
    return 0;
  }

protected:
  int SetNodePara() override {
    if (!dnn_node_para_ptr_) {
      dnn_node_para_ptr_ = std::make_shared<DnnNodePara>();
    }
    
    dnn_node_para_ptr_->model_file = model_path_;
    dnn_node_para_ptr_->model_task_type = ModelTaskType::ModelInferType;
    dnn_node_para_ptr_->task_num = 2;
    
    RCLCPP_INFO(this->get_logger(), "Loading model: %s", model_path_.c_str());
    return 0;
  }
  
  int PostProcess(const std::shared_ptr<DnnNodeOutput> &output) override {
    if (!output || output->output_tensors.empty()) {
      return -1;
    }
    
    auto start_time = std::chrono::high_resolution_clock::now();
    
    // Get depth output tensor
    auto& depth_tensor = output->output_tensors[0];
    if (!depth_tensor) {
      return -1;
    }
    
    // Invalidate cache to ensure we read latest data from BPU
    depth_tensor->CACHE_INVALIDATE();
    
    // Parse depth output (inverse depth)
    int h = depth_tensor->properties.validShape.dimensionSize[1];
    int w = depth_tensor->properties.validShape.dimensionSize[2];
    
    float* depth_data = depth_tensor->GetTensorData<float>();
    
    // === Ground-Plane Calibrated Depth Conversion ===
    // Instead of naive 1/inv_depth (which maps ground pixels to ~0.4m phantom walls),
    // use camera height + pixel row angles to anchor depth to real-world metric.
    
    // Step 1: Check depth variation
    float inv_min = 1e30f, inv_max = -1e30f;
    for (int i = 0; i < h * w; i++) {
      float v = depth_data[i];
      if (v < inv_min) inv_min = v;
      if (v > inv_max) inv_max = v;
    }
    float inv_range = inv_max - inv_min;
    float ground_depth_ref = max_depth_f_;  // will be updated by calibration
    
    std::vector<float> depth_map(h * w);
    
    // Lazy-init row angles based on actual model output size
    if (row_angles_.size() != static_cast<size_t>(h)) {
      double fov_v_rad = fov_v_ * M_PI / 180.0;
      double half_angle = fov_v_rad / 2.0 + camera_pitch_ * M_PI / 180.0;
      ground_half_angle_ = static_cast<float>(half_angle);
      row_angles_.resize(h);
      for (int v = 0; v < h; v++) {
        row_angles_[v] = static_cast<float>(
          ((v + 0.5) / h - 0.5) * 2.0 * half_angle);
      }
      RCLCPP_INFO(this->get_logger(), 
                  "Ground-plane calib: model %dx%d, row angles %.1f°~%.1f°, half=%.1f°",
                  h, w,
                  row_angles_[0] * 180.0 / M_PI,
                  row_angles_[h-1] * 180.0 / M_PI,
                  ground_half_angle_ * 180.0 / M_PI);
    }
    
    if (inv_range < 5.0f) {
      // Insufficient depth variation — fill with max_depth
      std::fill(depth_map.begin(), depth_map.end(), max_depth_f_);
    } else {
      // Step 2: Ground anchor from bottom 25% of image
      int bottom_start = static_cast<int>(h * 0.75f);
      float ground_inv_sum = 0.0f;
      int ground_inv_count = 0;
      for (int v = bottom_start; v < h; v++) {
        for (int u = 0; u < w; u++) {
          ground_inv_sum += depth_data[v * w + u];
          ground_inv_count++;
        }
      }
      float ground_inv = ground_inv_sum / std::max(1, ground_inv_count);
      
      // Compute real ground depth for bottom region rows
      // ground_depth = camera_z / sin(α) where α is angle below horizontal
      float ground_depth_sum = 0.0f;
      int ground_depth_count = 0;
      for (int v = bottom_start; v < h; v++) {
        float angle = row_angles_[v];  // radians, positive=down
        float sin_a = std::sin(angle);
        if (sin_a > 0.05f) {  // at least 3° below horizontal
          float real_depth = static_cast<float>(camera_z_) / sin_a;
          ground_depth_sum += real_depth;
          ground_depth_count++;
        }
      }
      float ground_depth_ref_local = (ground_depth_count > 0) 
        ? ground_depth_sum / ground_depth_count : 2.5f;
      ground_depth_ref = ground_depth_ref_local;
      float ground_inv_real = 1.0f / std::max(ground_depth_ref, 0.3f);
      
      // Step 3: Horizon/far anchor from top 20% of image
      int top_end = static_cast<int>(h * 0.20f);
      float horizon_inv_sum = 0.0f;
      int horizon_inv_count = 0;
      for (int v = 0; v < top_end; v++) {
        for (int u = 0; u < w; u++) {
          horizon_inv_sum += depth_data[v * w + u];
          horizon_inv_count++;
        }
      }
      float horizon_inv = horizon_inv_sum / std::max(1, horizon_inv_count);
      float horizon_inv_real = 1.0f / max_depth_f_;
      
      // Step 4: Build linear mapping: model_inv = slope * real_inv + intercept
      float inv_model_diff = ground_inv - horizon_inv;
      
      if (std::abs(inv_model_diff) < 1.0f) {
        // Insufficient depth variation — fill with max_depth
        std::fill(depth_map.begin(), depth_map.end(), max_depth_f_);
      } else {
        float slope = inv_model_diff / (ground_inv_real - horizon_inv_real);
        float intercept = ground_inv - slope * ground_inv_real;
        
        if (std::abs(slope) < 1e-6f) {
          std::fill(depth_map.begin(), depth_map.end(), max_depth_f_);
        } else {
          // Step 5: Convert all pixels using calibrated mapping
          for (int i = 0; i < h * w; i++) {
            float real_inv = (depth_data[i] - intercept) / slope;
            if (real_inv > 1e-6f) {
              depth_map[i] = std::max(min_depth_f_, std::min(max_depth_f_, 1.0f / real_inv));
            } else {
              depth_map[i] = max_depth_f_;
            }
          }
        }
      }
    }
    
    // Temporal EMA smoothing on depth map (reduces frame-to-frame jitter)
    if (has_prev_depth_ && prev_depth_map_.size() == depth_map.size()) {
      for (int i = 0; i < h * w; i++) {
        depth_map[i] = SMOOTH_ALPHA * depth_map[i] + (1.0f - SMOOTH_ALPHA) * prev_depth_map_[i];
      }
    }
    prev_depth_map_ = depth_map;
    has_prev_depth_ = true;
    
    // Generate point cloud
    std::vector<Point3D> points;
    generate_pointcloud(depth_map, h, w, points);
    
    // Publish point cloud
    publish_pointcloud(points, output->msg_header);
    
    auto end_time = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
    
    // Log stats periodically
    frame_count_++;
    if (frame_count_ % 100 == 0) {
      // Count near-field points (<0.8m) for diagnostics
      int near_count = 0;
      float x_min = 10.0f, x_max = 0.0f;
      for (const auto& p : points) {
        if (p.x < 0.8f) near_count++;
        if (p.x < x_min) x_min = p.x;
        if (p.x > x_max) x_max = p.x;
      }
      if (points.empty()) { x_min = 0; x_max = 0; }
      RCLCPP_INFO(this->get_logger(), 
                  "Frame %d: %zu pts (%d near<0.8m), x: %.2f~%.2fm, inv: %.0f, gnd_ref: %.2fm, post: %ldms",
                  frame_count_, points.size(), near_count,
                  x_min, x_max, inv_range, ground_depth_ref, duration.count());
    }
    
    return 0;
  }

private:
  // Parameters
  std::string model_path_;
  int camera_id_;
  int camera_width_, camera_height_;
  double fps_;
  
  double fov_h_, fov_v_;
  double camera_x_, camera_y_, camera_z_, camera_pitch_;
  
  double min_depth_, max_depth_;
  float min_depth_f_, max_depth_f_;
  double ground_height_threshold_;
  int point_stride_;
  double publish_rate_;
  
  // Camera
  cv::VideoCapture camera_;
  std::thread camera_thread_;       // Producer: capture + publish
  std::thread inference_thread_;    // Consumer: convert + infer + postprocess
  std::atomic<bool> running_{false};
  
  // Double-buffered frame exchange (producer → consumer)
  std::mutex frame_mutex_;
  cv::Mat shared_frame_;            // Latest frame from producer
  rclcpp::Time shared_stamp_;       // Unified timestamp
  bool frame_ready_ = false;        // Signal: new frame available
  std::condition_variable frame_cv_;
  
  // Consumer's previous frame (for reuse when producer is stuck)
  cv::Mat prev_frame_;
  bool has_prev_frame_ = false;
  
  // Frame cache: reuse last valid frame when camera fails
  cv::Mat last_valid_frame_;
  bool has_cached_frame_ = false;
  int consecutive_failures_ = 0;
  static constexpr int MAX_CONSECUTIVE_FAILURES = 100;  // warn every 100 fails
  static constexpr int FAIL_RETRY_MS = 50;              // retry interval on failure
  
  // Intrinsics
  CameraIntrinsics intrinsics_;
  
  // Transforms
  std::array<std::array<float, 3>, 3> R_cam_to_base_;
  std::array<float, 3> t_cam_to_base_;
  
  // Publisher
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pointcloud_pub_;
  rclcpp::Publisher<sensor_msgs::msg::CameraInfo>::SharedPtr camera_info_pub_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr image_pub_;
  
  // CameraInfo message (pre-built, only stamp updated per publish)
  sensor_msgs::msg::CameraInfo camera_info_msg_;
  
  // Publishing toggles
  bool publish_camera_info_ = true;
  bool publish_raw_image_ = true;
  std::string camera_info_topic_;
  std::string image_topic_;
  
  // Image throttle constants (used by inference thread for Foxglove viewing)
  static constexpr int IMAGE_SKIP = 3;  // publish every 3rd frame (~10 Hz at 31 FPS) — saves WiFi bandwidth
  
  // Async image publisher — decouples publish from inference cycle
  std::thread image_pub_thread_;
  std::mutex image_pub_mutex_;
  std::condition_variable image_pub_cv_;
  cv::Mat image_pub_frame_;        // Latest frame queued for publishing
  rclcpp::Time image_pub_stamp_;
  bool image_pub_ready_ = false;
  int infer_img_skip_ = 0;
  
  // Stats
  int frame_count_ = 0;
  int infer_frame_count_ = 0;
  
  // Temporal smoothing buffer (EMA on depth map)
  std::vector<float> prev_depth_map_;
  bool has_prev_depth_ = false;
  static constexpr float SMOOTH_ALPHA = 0.6f;  // 0.6 = responsive, 0.4 = smooth
  
  // Ground-plane calibration: precomputed row angles
  std::vector<float> row_angles_;  // per-row angle from horizontal (radians, positive=down)
  float ground_half_angle_ = 0.0f;
  
  void precompute_transforms() {
    // Camera to base_link transformation
    // Camera frame (OpenCV): X=right, Y=down, Z=forward
    // Base frame (ROS): X=forward, Y=left, Z=up
    
    R_cam_to_base_[0] = {0, 0, 1};
    R_cam_to_base_[1] = {-1, 0, 0};
    R_cam_to_base_[2] = {0, -1, 0};
    
    // Apply pitch rotation
    double pitch_rad = camera_pitch_ * M_PI / 180.0;
    float cos_p = std::cos(pitch_rad);
    float sin_p = std::sin(pitch_rad);
    
    std::array<std::array<float, 3>, 3> R_pitch = {{
      {cos_p, 0, sin_p},
      {0, 1, 0},
      {-sin_p, 0, cos_p}
    }};
    
    // Multiply: R_cam_to_base = R_base * R_pitch
    auto R_base = R_cam_to_base_;
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        R_cam_to_base_[i][j] = 0;
        for (int k = 0; k < 3; k++) {
          R_cam_to_base_[i][j] += R_base[i][k] * R_pitch[k][j];
        }
      }
    }
    
    // Translation
    t_cam_to_base_ = {static_cast<float>(camera_x_), 
                      static_cast<float>(camera_y_), 
                      static_cast<float>(camera_z_)};
    
    min_depth_f_ = static_cast<float>(min_depth_);
    max_depth_f_ = static_cast<float>(max_depth_);
    
    // Precompute per-row vertical angles for ground-plane calibration
    // NOTE: Will be recomputed in PostProcess when actual model output size is known
    ground_half_angle_ = 0.0f;  // flag: not yet computed for model size
  }
  
  bool open_camera() {
    camera_.open(camera_id_, cv::CAP_V4L2);
    if (!camera_.isOpened()) {
      RCLCPP_ERROR(this->get_logger(), "Failed to open camera %d", camera_id_);
      return false;
    }
    
    camera_.set(cv::CAP_PROP_FRAME_WIDTH, camera_width_);
    camera_.set(cv::CAP_PROP_FRAME_HEIGHT, camera_height_);
    camera_.set(cv::CAP_PROP_FPS, fps_);
    // Prefer MJPEG — more robust under USB EMI (lower bandwidth than YUYV)
    camera_.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc('M','J','P','G'));
    camera_.set(cv::CAP_PROP_CONVERT_RGB, true);
    
    // Verify format
    int fourcc = static_cast<int>(camera_.get(cv::CAP_PROP_FOURCC));
    char fmt[5] = {
      static_cast<char>(fourcc & 0xFF),
      static_cast<char>((fourcc >> 8) & 0xFF),
      static_cast<char>((fourcc >> 16) & 0xFF),
      static_cast<char>((fourcc >> 24) & 0xFF),
      '\0'
    };
    
    RCLCPP_INFO(this->get_logger(), "Camera opened: %dx%d, format: %s", 
                camera_width_, camera_height_, fmt);
    return true;
  }
  
  // ==========================================================================
  // IMAGE PUBLISHER THREAD: Async image publishing (decoupled from inference)
  // Receives frames from inference thread, resizes and publishes independently
  // ==========================================================================
  void image_publish_loop() {
    RCLCPP_INFO(this->get_logger(), "Image publish thread started");
    
    while (running_) {
      cv::Mat frame;
      rclcpp::Time stamp;
      
      {
        std::unique_lock<std::mutex> lock(image_pub_mutex_);
        image_pub_cv_.wait_for(lock, std::chrono::milliseconds(200),
                               [this]() { return image_pub_ready_ || !running_.load(); });
        if (!running_) break;
        if (!image_pub_ready_) continue;
        frame = image_pub_frame_;  // shallow copy, data stays valid
        stamp = image_pub_stamp_;
        image_pub_ready_ = false;
      }
      
      if (frame.empty()) continue;
      
      // Resize to thumbnail and publish — runs in dedicated thread, doesn't block BPU
      cv::Mat thumb;
      cv::resize(frame, thumb, cv::Size(320, 240), 0, 0, cv::INTER_NEAREST);
      
      auto img_msg = sensor_msgs::msg::Image();
      img_msg.header.stamp = stamp;
      img_msg.header.frame_id = "camera_link";
      img_msg.height = thumb.rows;
      img_msg.width = thumb.cols;
      img_msg.encoding = "bgr8";
      img_msg.is_bigendian = false;
      img_msg.step = thumb.cols * 3;
      img_msg.data.assign(thumb.data, thumb.data + thumb.total() * thumb.elemSize());
      image_pub_->publish(img_msg);
    }
  }
  
  // ==========================================================================
  // PRODUCER THREAD: Camera capture + CameraInfo/Image publishing
  // Runs independently at camera FPS (~30Hz), never blocked by BPU inference
  // ==========================================================================
  void capture_loop() {
    cv::Mat frame;
    double frame_interval_us = 1e6 / fps_;
    
    RCLCPP_INFO(this->get_logger(), "Capture thread started (target: %.0f FPS)", fps_);
    
    while (running_) {
      auto t0 = std::chrono::high_resolution_clock::now();
      
      // --- Unified timestamp for ALL published data ---
      auto capture_stamp = this->now();
      
      // --- Frame capture with cache fallback ---
      bool capture_ok = camera_.read(frame) && !frame.empty();
      
      if (capture_ok) {
        frame.copyTo(last_valid_frame_);
        has_cached_frame_ = true;
        consecutive_failures_ = 0;
      } else {
        consecutive_failures_++;
        if (has_cached_frame_) {
          frame = last_valid_frame_;
          if (consecutive_failures_ == 1) {
            RCLCPP_WARN(this->get_logger(), "Camera capture failed, reusing cached frame");
          } else if (consecutive_failures_ % MAX_CONSECUTIVE_FAILURES == 0) {
            RCLCPP_WARN(this->get_logger(), 
                        "Camera still failing (%d consecutive), using cached frame",
                        consecutive_failures_);
          }
        } else {
          if (consecutive_failures_ == 1) {
            RCLCPP_WARN(this->get_logger(), "Failed to capture frame (no cache yet)");
          }
          std::this_thread::sleep_for(std::chrono::milliseconds(FAIL_RETRY_MS));
          continue;
        }
      }
      
      // --- Publish CameraInfo only (lightweight, no resize needed) ---
      if (publish_camera_info_ && camera_info_pub_) {
        camera_info_msg_.header.stamp = capture_stamp;
        camera_info_pub_->publish(camera_info_msg_);
      }
      
      // Raw image publishing moved to inference thread (not blocked by USB EMI)
      
      // --- Hand frame to inference consumer via double-buffer ---
      {
        std::lock_guard<std::mutex> lock(frame_mutex_);
        frame.copyTo(shared_frame_);
        shared_stamp_ = capture_stamp;
        frame_ready_ = true;
      }
      frame_cv_.notify_one();
      
      // --- Frame rate control ---
      auto t1 = std::chrono::high_resolution_clock::now();
      auto elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
      int sleep_us = static_cast<int>(frame_interval_us) - elapsed_us;
      if (sleep_us > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(sleep_us));
      }
    }
  }
  
  // ==========================================================================
  // CONSUMER THREAD: BPU inference + depth post-processing
  // Picks latest frame from buffer, runs MiDaS, publishes point cloud
  // ==========================================================================
  void inference_loop() {
    RCLCPP_INFO(this->get_logger(), "Inference thread started");
    
    cv::Mat frame;
    rclcpp::Time stamp;
    
    while (running_) {
      // --- Wait for latest frame from producer (non-blocking after initial frame) ---
      bool got_new_frame = false;
      
      {
        std::unique_lock<std::mutex> lock(frame_mutex_);
        if (frame_ready_ || !has_prev_frame_) {
          // Wait for new frame (with timeout for first frame, no wait for subsequent)
          frame_cv_.wait_for(lock, std::chrono::milliseconds(has_prev_frame_ ? 5 : 500),
                             [this]() { return frame_ready_ || !running_.load(); });
        }
        if (!running_) break;
        
        if (frame_ready_) {
          frame = shared_frame_.clone();
          stamp = shared_stamp_;
          frame_ready_ = false;
          got_new_frame = true;
        }
      }
      
      // Reuse previous frame if no new frame available (producer stuck on USB EMI)
      if (!got_new_frame) {
        if (has_prev_frame_) {
          frame = prev_frame_.clone();
          stamp = this->now();  // fresh timestamp for reused frame
        } else {
          continue;  // no frame at all, retry
        }
      } else {
        frame.copyTo(prev_frame_);
        has_prev_frame_ = true;
      }
      
      if (frame.empty()) continue;
      
      // --- Queue raw image for async publish (non-blocking, doesn't stall inference) ---
      if (publish_raw_image_ && image_pub_) {
        if (++infer_img_skip_ >= IMAGE_SKIP) {
          infer_img_skip_ = 0;
          {
            std::lock_guard<std::mutex> lock(image_pub_mutex_);
            frame.copyTo(image_pub_frame_);
            image_pub_stamp_ = stamp;
            image_pub_ready_ = true;
          }
          image_pub_cv_.notify_one();
        }
      }
      
      auto t_prev_end = std::chrono::high_resolution_clock::now();
      auto t0 = std::chrono::high_resolution_clock::now();
      
      // --- Convert BGR → NV12 (resize 640×480 → 384×384 + color space) ---
      auto t0b = std::chrono::high_resolution_clock::now();
      auto t1 = std::chrono::high_resolution_clock::now();
      auto input = bgr_to_nv12(frame);
      auto t2 = std::chrono::high_resolution_clock::now();
      
      if (!input) {
        RCLCPP_ERROR(this->get_logger(), "Failed to convert frame to NV12");
        continue;
      }
      
      // --- Create output with unified capture timestamp ---
      auto output = std::make_shared<DnnNodeOutput>();
      output->msg_header = std::make_shared<std_msgs::msg::Header>();
      output->msg_header->stamp = stamp;
      output->msg_header->frame_id = "base_link";
      
      // --- Run BPU inference (sync) ---
      std::vector<std::shared_ptr<DNNInput>> inputs = {input};
      int ret = Run(inputs, output, nullptr, true);  // sync mode
      
      auto t3 = std::chrono::high_resolution_clock::now();
      
      if (ret != 0) {
        RCLCPP_WARN(this->get_logger(), "Inference failed: %d", ret);
        continue;
      }
      
      // --- Log per-stage timing periodically ---
      infer_frame_count_++;
      if (infer_frame_count_ % 200 == 0) {
        auto ms_wait = std::chrono::duration_cast<std::chrono::microseconds>(t0b - t_prev_end).count() / 1000.0;
        auto ms_clone = std::chrono::duration_cast<std::chrono::microseconds>(t0b - t0).count() / 1000.0;
        auto ms_convert = std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count() / 1000.0;
        auto ms_infer = std::chrono::duration_cast<std::chrono::microseconds>(t3 - t2).count() / 1000.0;
        auto ms_total = std::chrono::duration_cast<std::chrono::microseconds>(t3 - t_prev_end).count() / 1000.0;
        RCLCPP_INFO(this->get_logger(),
                    "Infer #%d: wait=%.1f clone=%.1f conv=%.1f infer=%.1f cycle=%.1fms (%.0f FPS)",
                    infer_frame_count_, ms_wait, ms_clone, ms_convert, ms_infer, ms_total,
                    1000.0 / ms_total);
      }
    }
  }
  
  std::shared_ptr<ManagedNV12Input> bgr_to_nv12(const cv::Mat& bgr) {
    // Resize to model input size — INTER_NEAREST is ~3x faster than INTER_LINEAR
    // and sufficient for depth estimation (no visible quality loss for MiDaS)
    cv::Mat resized;
    cv::resize(bgr, resized, cv::Size(intrinsics_.width, intrinsics_.height),
               0, 0, cv::INTER_NEAREST);
    
    // Convert BGR to YUV I420
    cv::Mat yuv_i420;
    cv::cvtColor(resized, yuv_i420, cv::COLOR_BGR2YUV_I420);
    
    int h = intrinsics_.height;
    int w = intrinsics_.width;
    int y_size = w * h;
    int uv_size = w * h / 4;
    
    // Create managed NV12 input with automatic memory cleanup
    auto input = std::make_shared<ManagedNV12Input>();
    input->height = h;
    input->width = w;
    input->y_stride = w;
    input->uv_stride = w;
    
    // Allocate BPU memory for Y plane
    int ret = hbSysAllocCachedMem(&input->y_mem, y_size);
    if (ret != 0) {
      RCLCPP_ERROR(this->get_logger(), "Failed to allocate Y plane BPU memory: %d", ret);
      return nullptr;
    }
    input->y_phy_addr = input->y_mem.phyAddr;
    input->y_vir_addr = input->y_mem.virAddr;
    
    // Copy Y plane data
    std::memcpy(input->y_mem.virAddr, yuv_i420.data, y_size);
    
    // Allocate BPU memory for UV plane
    ret = hbSysAllocCachedMem(&input->uv_mem, uv_size * 2);  // UV interleaved
    if (ret != 0) {
      RCLCPP_ERROR(this->get_logger(), "Failed to allocate UV plane BPU memory: %d", ret);
      hbSysFreeMem(&input->y_mem);
      return nullptr;
    }
    input->uv_phy_addr = input->uv_mem.phyAddr;
    input->uv_vir_addr = input->uv_mem.virAddr;
    
    // Convert I420 to NV12 (interleave U and V) — optimized with row-wise memcpy
    const uint8_t* u_plane = yuv_i420.data + y_size;
    const uint8_t* v_plane = u_plane + uv_size;
    uint8_t* uv_dst = static_cast<uint8_t*>(input->uv_mem.virAddr);
    
    int uv_w = w / 2;  // UV plane width
    int uv_h = h / 2;  // UV plane height
    for (int row = 0; row < uv_h; row++) {
      const uint8_t* u_row = u_plane + row * uv_w;
      const uint8_t* v_row = v_plane + row * uv_w;
      uint8_t* dst_row = uv_dst + row * w;  // w = 2 * uv_w (interleaved)
      for (int col = 0; col < uv_w; col++) {
        dst_row[col * 2] = u_row[col];
        dst_row[col * 2 + 1] = v_row[col];
      }
    }
    
    // Flush cache to ensure BPU sees the data
    hbSysFlushMem(&input->y_mem, HB_SYS_MEM_CACHE_CLEAN);
    hbSysFlushMem(&input->uv_mem, HB_SYS_MEM_CACHE_CLEAN);
    
    input->allocated = true;
    return input;
  }
  
  void generate_pointcloud(const std::vector<float>& depth_map, int h, int w,
                          std::vector<Point3D>& points) {
    points.clear();
    points.reserve(5000);
    
    // Filter upper half (ceiling/wall) — push to max_depth
    std::vector<float> filtered_depth = depth_map;
    for (int v = 0; v < h / 2; v++) {
      for (int u = 0; u < w; u++) {
        int idx = v * w + u;
        if (filtered_depth[idx] < 2.0f) {
          filtered_depth[idx] = max_depth_f_;
        }
      }
    }
    
    // Near-field masks: skip unreliable image regions
    int bottom_skip = static_cast<int>(h * 0.05);   // bottom 5%: too close, noisy
    int side_skip = static_cast<int>(w * 0.08);      // outer 8% each side: lens distortion
    
    // Precompute per-row ground depth (for ground-relative filtering)
    // For row v with angle α (from horizontal, positive=down):
    //   ground_depth = camera_z / sin(α)
    std::vector<float> row_ground_depth(h, max_depth_f_);
    float min_sin = 0.08f;  // ~4.6° — below this, can't reliably see ground
    for (int v = 0; v < h; v++) {
      if (v < static_cast<int>(row_angles_.size())) {
        float sin_a = std::sin(row_angles_[v]);
        if (sin_a > min_sin) {
          row_ground_depth[v] = static_cast<float>(camera_z_) / sin_a;
        }
      }
    }
    
    // Generate points with stride
    for (int v = bottom_skip; v < h; v += point_stride_) {
      float ground_d = row_ground_depth[v];
      
      for (int u = side_skip; u < w - side_skip; u += point_stride_) {
        int idx = v * w + u;
        float z_cam = filtered_depth[idx];
        
        // Skip far points (beyond near-field zone)
        if (z_cam >= max_depth_f_) continue;
        
        // *** Ground-relative depth filter ***
        // If this pixel sees ground at ground_d, and the measured depth is close
        // to ground_d, it's a ground pixel — skip it.
        if (z_cam > ground_d * 0.7f && z_cam < ground_d * 1.3f) {
          // Depth is close to expected ground distance — this is ground
          continue;
        }
        
        // Back-project to camera frame
        float x_cam = (u - intrinsics_.cx) * z_cam / intrinsics_.fx;
        float y_cam = (v - intrinsics_.cy) * z_cam / intrinsics_.fy;
        
        // Transform to base_link frame
        float x_base = R_cam_to_base_[0][0] * x_cam + R_cam_to_base_[0][1] * y_cam + R_cam_to_base_[0][2] * z_cam + t_cam_to_base_[0];
        float y_base = R_cam_to_base_[1][0] * x_cam + R_cam_to_base_[1][1] * y_cam + R_cam_to_base_[1][2] * z_cam + t_cam_to_base_[1];
        float z_base = R_cam_to_base_[2][0] * x_cam + R_cam_to_base_[2][1] * y_cam + R_cam_to_base_[2][2] * z_cam + t_cam_to_base_[2];
        
        // Ground filter: skip points at ground level
        if (z_base < ground_height_threshold_) continue;
        
        // Range filter: only forward, within near-field
        if (x_base < 0.1f || x_base > max_depth_f_) continue;
        
        // Lateral filter: tight cone (~50° half-angle)
        float lateral_ratio = std::abs(y_base) / std::max(0.1f, x_base);
        if (lateral_ratio > 1.2f) continue;
        
        // Height filter: ignore above 2.0m (ceilings, high shelves)
        if (z_base > 2.0f) continue;
        
        points.push_back({x_base, y_base, z_base});
      }
    }
  }
  
  void publish_pointcloud(const std::vector<Point3D>& points,
                         const std::shared_ptr<std_msgs::msg::Header>& header) {
    auto msg = sensor_msgs::msg::PointCloud2();
    
    msg.header = *header;
    msg.header.frame_id = "base_link";
    
    msg.height = 1;
    msg.width = points.size();
    
    // Define point fields
    sensor_msgs::msg::PointField field_x, field_y, field_z;
    
    field_x.name = "x";
    field_x.offset = 0;
    field_x.datatype = sensor_msgs::msg::PointField::FLOAT32;
    field_x.count = 1;
    
    field_y.name = "y";
    field_y.offset = 4;
    field_y.datatype = sensor_msgs::msg::PointField::FLOAT32;
    field_y.count = 1;
    
    field_z.name = "z";
    field_z.offset = 8;
    field_z.datatype = sensor_msgs::msg::PointField::FLOAT32;
    field_z.count = 1;
    
    msg.fields = {field_x, field_y, field_z};
    
    msg.point_step = 12;  // 3 floats
    msg.row_step = msg.point_step * msg.width;
    msg.is_bigendian = false;
    msg.is_dense = true;
    
    // Fill data
    msg.data.resize(msg.row_step * msg.height);
    float* data_ptr = reinterpret_cast<float*>(msg.data.data());
    
    for (size_t i = 0; i < points.size(); i++) {
      data_ptr[i * 3] = points[i].x;
      data_ptr[i * 3 + 1] = points[i].y;
      data_ptr[i * 3 + 2] = points[i].z;
    }
    
    pointcloud_pub_->publish(msg);
  }
};

}  // namespace midas_nav

int main(int argc, char** argv) {
  rclcpp::init(argc, argv);
  
  auto node = std::make_shared<midas_nav::MidasDepthNode>();
  
  if (node->start() != 0) {
    RCLCPP_ERROR(node->get_logger(), "Failed to start MiDaS Depth Node");
    return 1;
  }
  
  rclcpp::spin(node);
  rclcpp::shutdown();
  
  return 0;
}
