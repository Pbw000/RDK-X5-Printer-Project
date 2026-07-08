// MiDaS Web Demo — C++ standalone version for RDK X5
// BPU inference via hb_dnn C API, no ROS2 dependency
// HTTP server with MJPEG stream + REST API + embedded web UI
//
// Build: make -C /path/to/midas_nav_alt/web_demo
// Run:   ./midas_web_demo [--port 8080] [--model path] [--camera /dev/video0]

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <opencv2/opencv.hpp>
#include "dnn/hb_dnn.h"
#include "dnn/hb_sys.h"

// ============================================================================
// Configuration
// ============================================================================

struct Config {
    std::string model_path = "/path/to/midas_nav_alt/models/midas_small_384_v2.bin";
    std::string camera_device = "/dev/video0";
    std::string config_path = "/path/to/midas_nav_alt/config/midas_nav_params.yaml";
    int camera_width = 640;
    int camera_height = 480;
    int camera_fps = 30;
    int port = 8080;

    // Calibration params
    double fov_h = 73.7;
    double fov_v = 55.3;
    double camera_x = 0.11;
    double camera_y = 0.0;
    double camera_z = 0.72;
    double camera_pitch = 0.0;
    double min_depth = 0.5;
    double max_depth = 3.5;
    double ground_height_threshold = 0.25;
    int point_stride = 6;
};

// ============================================================================
// Global state
// ============================================================================

static Config g_config;
static std::mutex g_mutex;

struct Stats {
    double fps = 0;
    double infer_time_ms = 0;
    int point_count = 0;
    double depth_min = 0, depth_max = 0;
};

static Stats g_stats;
static cv::Mat g_frame;       // latest BGR frame
static cv::Mat g_depth_map;   // latest depth map (float32, HxW)
static std::vector<float> g_points; // [x,y,z, x,y,z, ...] in base_link
static std::atomic<bool> g_running{true};

// ============================================================================
// BPU Inference (hb_dnn C API)
// ============================================================================

struct BPUModel {
    hbPackedDNNHandle_t packed_handle = nullptr;
    hbDNNHandle_t model_handle = nullptr;
    int model_size = 384;

    // Input/Output tensor memory
    hbSysMem input_mem = {};       // Single contiguous NV12 buffer (Y + UV)
    hbDNNTensor input_tensor = {};

    // Pre-allocated output tensor
    hbDNNTensor output_tensor = {};
    hbSysMem output_mem = {};
    int output_h = 0, output_w = 0;

    bool load(const std::string& path) {
        const char* model_files[] = { path.c_str() };
        int ret = hbDNNInitializeFromFiles(&packed_handle, model_files, 1);
        if (ret != 0) {
            std::cerr << "hbDNNInitializeFromFiles failed: " << ret << std::endl;
            return false;
        }

        const char** name_list = nullptr;
        int32_t model_count = 0;
        hbDNNGetModelNameList(&name_list, &model_count, packed_handle);
        if (model_count <= 0) {
            std::cerr << "No models found" << std::endl;
            return false;
        }

        hbDNNGetModelHandle(&model_handle, packed_handle, name_list[0]);

        // Get input properties
        int32_t input_count = 0;
        hbDNNGetInputCount(&input_count, model_handle);
        hbDNNTensorProperties input_props;
        hbDNNGetInputTensorProperties(&input_props, model_handle, 0);

        // Parse model size from input shape
        if (input_props.validShape.numDimensions >= 3) {
            int ndim = input_props.validShape.numDimensions;
            if (ndim == 4) {
                model_size = input_props.validShape.dimensionSize[2];
            } else if (ndim == 3) {
                model_size = input_props.validShape.dimensionSize[1];
            }
        }

        std::cout << "Model loaded: " << name_list[0]
                  << ", input size: " << model_size << "x" << model_size << std::endl;

        // Allocate single contiguous NV12 buffer (Y + UV interleaved)
        int y_size = model_size * model_size;           // Y plane
        int uv_size = model_size * model_size / 2;      // UV interleaved
        int nv12_total = y_size + uv_size;              // Full NV12

        hbSysAllocCachedMem(&input_mem, nv12_total);

        // Setup input tensor — single sysMem with full NV12
        memset(&input_tensor, 0, sizeof(input_tensor));
        input_tensor.properties = input_props;
        input_tensor.sysMem[0].virAddr = input_mem.virAddr;
        input_tensor.sysMem[0].phyAddr = input_mem.phyAddr;
        input_tensor.sysMem[0].memSize = nv12_total;

        // --- Pre-allocate output tensor ---
        int32_t output_count = 0;
        hbDNNGetOutputCount(&output_count, model_handle);
        std::cout << "Output count: " << output_count << std::endl;

        hbDNNTensorProperties output_props;
        hbDNNGetOutputTensorProperties(&output_props, model_handle, 0);

        // Parse output dimensions
        int ndim = output_props.validShape.numDimensions;
        int total_elements = 1;
        output_h = model_size;
        output_w = model_size;

        std::cout << "Output ndim: " << ndim << ", shape: [";
        for (int d = 0; d < ndim; d++) {
            std::cout << output_props.validShape.dimensionSize[d];
            if (d < ndim-1) std::cout << ",";
            total_elements *= output_props.validShape.dimensionSize[d];
        }
        std::cout << "]" << std::endl;

        // For shape [1, H, W, 1] (NHWC), extract H and W from dims 1 and 2
        if (ndim == 4) {
            output_h = output_props.validShape.dimensionSize[1];
            output_w = output_props.validShape.dimensionSize[2];
        } else if (ndim == 3) {
            output_h = output_props.validShape.dimensionSize[0];
            output_w = output_props.validShape.dimensionSize[1];
        } else if (ndim >= 2) {
            output_h = output_props.validShape.dimensionSize[ndim - 2];
            output_w = output_props.validShape.dimensionSize[ndim - 1];
        }

        // Allocate based on total elements (all dims product)
        uint32_t out_size = total_elements * sizeof(float);
        std::cout << "Output size: " << output_h << "x" << output_w
                  << " = " << out_size << " bytes" << std::endl;

        hbSysAllocCachedMem(&output_mem, out_size);

        // Setup output tensor
        memset(&output_tensor, 0, sizeof(output_tensor));
        output_tensor.properties = output_props;
        output_tensor.sysMem[0].virAddr = output_mem.virAddr;
        output_tensor.sysMem[0].phyAddr = output_mem.phyAddr;
        output_tensor.sysMem[0].memSize = out_size;

        return true;
    }

    // Returns inverse depth map (float64 vector, HxW)
    bool infer(const cv::Mat& bgr_frame, std::vector<double>& depth_inv) {
        int sz = model_size;
        int y_size = sz * sz;
        int uv_size = sz * sz / 4;

        // Resize + BGR -> YUV I420 -> NV12 (single contiguous buffer)
        cv::Mat resized;
        cv::resize(bgr_frame, resized, cv::Size(sz, sz));

        cv::Mat yuv_i420;
        cv::cvtColor(resized, yuv_i420, cv::COLOR_BGR2YUV_I420);

        uint8_t* nv12_buf = (uint8_t*)input_mem.virAddr;

        // Copy Y plane directly
        memcpy(nv12_buf, yuv_i420.data, y_size);

        // Convert I420 split U/V to NV12 interleaved UV
        const uint8_t* u_plane = yuv_i420.data + y_size;
        const uint8_t* v_plane = u_plane + uv_size;
        uint8_t* uv_dst = nv12_buf + y_size;

        for (int i = 0; i < uv_size; i++) {
            uv_dst[i * 2] = u_plane[i];
            uv_dst[i * 2 + 1] = v_plane[i];
        }

        // Flush cache
        hbSysFlushMem(&input_mem, HB_SYS_MEM_CACHE_CLEAN);

        // Run inference — pass pointer to pre-allocated output tensor
        hbDNNTaskHandle_t task = nullptr;
        hbDNNTensor* out_ptr = &output_tensor;
        hbDNNInferCtrlParam ctrl;
        HB_DNN_INITIALIZE_INFER_CTRL_PARAM((&ctrl));

        int ret = hbDNNInfer(&task, &out_ptr, &input_tensor, model_handle, &ctrl);
        if (ret != 0) {
            std::cerr << "hbDNNInfer failed: " << ret << std::endl;
            return false;
        }

        ret = hbDNNWaitTaskDone(task, 5000);
        if (ret != 0) {
            std::cerr << "hbDNNWaitTaskDone failed: " << ret << std::endl;
            hbDNNReleaseTask(task);
            return false;
        }

        // Invalidate cache to read from BPU
        hbSysFlushMem(&output_mem, HB_SYS_MEM_CACHE_INVALIDATE);

        float* data = (float*)output_mem.virAddr;
        int total = output_h * output_w;

        depth_inv.resize(total);
        for (int i = 0; i < total; i++) {
            depth_inv[i] = (double)data[i];
        }

        hbDNNReleaseTask(task);
        return true;
    }

    ~BPUModel() {
        if (input_mem.virAddr) hbSysFreeMem(&input_mem);
        if (output_mem.virAddr) hbSysFreeMem(&output_mem);
        if (packed_handle) hbDNNRelease(packed_handle);
    }
};

// ============================================================================
// Depth Processing — ground-plane calibration + filtering
// ============================================================================

void process_depth(const std::vector<double>& depth_inv, int H, int W,
                   cv::Mat& depth_map_out, std::vector<float>& points_out)
{
    const auto& cfg = g_config;
    points_out.clear();

    // Compute intrinsics from FOV
    double fx = W / (2.0 * std::tan(cfg.fov_h * M_PI / 360.0));
    double fy = H / (2.0 * std::tan(cfg.fov_v * M_PI / 360.0));
    double cx = W / 2.0;
    double cy = H / 2.0;

    // Find min/max inverse depth
    double d_min = *std::min_element(depth_inv.begin(), depth_inv.end());
    double d_max = *std::max_element(depth_inv.begin(), depth_inv.end());
    double inv_range = d_max - d_min;
    if (inv_range < 5.0) return;

    // Ground-plane calibration
    int bottom_start = (int)(H * 0.75);
    double ground_inv = 0;
    int gc = 0;
    for (int v = bottom_start; v < H; v++)
        for (int u = 0; u < W; u++) {
            ground_inv += depth_inv[v * W + u];
            gc++;
        }
    if (gc > 0) ground_inv /= gc;

    double fov_v_model = 2.0 * std::atan((H / 2.0) / fy);
    double half_angle = fov_v_model / 2.0 + cfg.camera_pitch * M_PI / 180.0;

    // Compute ground depth reference from bottom rows
    double ground_depth_ref = cfg.max_depth;
    {
        std::vector<double> gd;
        for (int v = bottom_start; v < H; v++) {
            double angle = ((v + 0.5) / H - 0.5) * 2.0 * half_angle;
            double cos_a = std::cos(angle);
            if (cos_a > 0.05) {
                gd.push_back(cfg.camera_z / cos_a);
            }
        }
        if (!gd.empty()) {
            std::sort(gd.begin(), gd.end());
            ground_depth_ref = gd[gd.size() / 2];
        }
    }
    double ground_inv_real = 1.0 / std::max(ground_depth_ref, 0.3);

    // Horizon reference from top 20%
    int top_end = (int)(H * 0.20);
    double horizon_inv = 0;
    int hc = 0;
    for (int v = 0; v < top_end; v++)
        for (int u = 0; u < W; u++) {
            horizon_inv += depth_inv[v * W + u];
            hc++;
        }
    if (hc > 0) horizon_inv /= hc;
    double horizon_inv_real = 1.0 / cfg.max_depth;

    // Linear mapping
    double inv_model_diff = ground_inv - horizon_inv;
    if (std::abs(inv_model_diff) < 1.0) return;

    double slope = inv_model_diff / (ground_inv_real - horizon_inv_real);
    double intercept = ground_inv - slope * ground_inv_real;
    if (std::abs(slope) < 1e-6) return;

    // Convert to depth map
    depth_map_out = cv::Mat(H, W, CV_32F);
    for (int i = 0; i < H * W; i++) {
        double real_inv = (depth_inv[i] - intercept) / slope;
        if (real_inv > 1e-6) {
            float d = (float)(1.0 / real_inv);
            d = std::max((float)cfg.min_depth, std::min((float)cfg.max_depth, d));
            depth_map_out.at<float>(i) = d;
        } else {
            depth_map_out.at<float>(i) = (float)cfg.max_depth;
        }
    }

    // Precompute row angles
    std::vector<double> row_angles(H);
    for (int v = 0; v < H; v++) {
        row_angles[v] = ((v + 0.5) / H - 0.5) * 2.0 * half_angle;
    }

    // Pitch rotation
    double pitch_rad = cfg.camera_pitch * M_PI / 180.0;
    float cos_p = (float)std::cos(pitch_rad), sin_p = (float)std::sin(pitch_rad);
    // R_cam_to_base = R_frame * R_pitch
    // R_frame: [0,0,1; -1,0,0; 0,-1,0]
    float R00=0, R01=0, R02=1;
    float R10=-1, R11=0, R12=0;
    float R20=0, R21=-1, R22=0;
    // Multiply by R_pitch: [cos_p,0,sin_p; 0,1,0; -sin_p,0,cos_p]
    float Rb[3][3] = {
        {R00*cos_p + R02*(-sin_p), R01, R00*sin_p + R02*cos_p},
        {R10*cos_p + R12*(-sin_p), R11, R10*sin_p + R12*cos_p},
        {R20*cos_p + R22*(-sin_p), R21, R20*sin_p + R22*cos_p}
    };

    int stride = cfg.point_stride;
    double ground_margin = std::max(cfg.ground_height_threshold, 0.25);
    double min_sin_angle = 0.08;

    for (int v = 0; v < H; v += stride) {
        double angle = row_angles[v];
        double abs_angle = std::abs(angle);
        double sin_angle = std::sin(abs_angle);

        // Expected ground depth for this row
        double d_ground = cfg.max_depth;
        if (angle > 0.01) {
            double cos_a = std::cos(angle);
            if (cos_a > 0.05) d_ground = std::min(cfg.camera_z / cos_a, cfg.max_depth);
        }

        for (int u = 0; u < W; u += stride) {
            float z_cam = depth_map_out.at<float>(v, u);
            if (z_cam >= (float)cfg.max_depth) continue;

            // Upper half filter: ceiling/wall pixels
            if (v < H / 2 && z_cam < 2.0f) {
                z_cam = (float)cfg.max_depth;
                continue;
            }

            // Back-project to camera frame
            float x_cam = (float)((u - cx) * z_cam / fx);
            float y_cam = (float)((v - cy) * z_cam / fy);

            // Transform to base_link
            float xb = Rb[0][0]*x_cam + Rb[0][1]*y_cam + Rb[0][2]*z_cam + (float)cfg.camera_x;
            float yb = Rb[1][0]*x_cam + Rb[1][1]*y_cam + Rb[1][2]*z_cam + (float)cfg.camera_y;
            float zb = Rb[2][0]*x_cam + Rb[2][1]*y_cam + Rb[2][2]*z_cam + (float)cfg.camera_z;

            // Ground-relative filter
            double z_above = (d_ground - z_cam) * sin_angle;
            bool below_horizon = angle > 0.01;
            bool use_ground_rel = below_horizon && sin_angle > min_sin_angle;

            bool above_ground;
            if (use_ground_rel) {
                above_ground = z_above > ground_margin;
            } else if (below_horizon) {
                above_ground = zb > 1.3f;
            } else {
                above_ground = zb > 0.25f;
            }
            if (!above_ground) continue;

            // Range filters
            if (xb < 0.10f || xb > (float)cfg.max_depth) continue;
            float lat = std::abs(yb) / std::max(0.1f, xb);
            if (lat > 1.2f) continue;
            if (zb > 2.5f) continue;

            points_out.push_back(xb);
            points_out.push_back(yb);
            points_out.push_back(zb);
        }
    }
}

// ============================================================================
// Inference Thread
// ============================================================================

void inference_thread_func() {
    BPUModel model;
    if (!model.load(g_config.model_path)) {
        std::cerr << "Failed to load BPU model!" << std::endl;
        return;
    }

    cv::VideoCapture cap(g_config.camera_device, cv::CAP_V4L2);
    if (!cap.isOpened()) {
        std::cerr << "Failed to open camera: " << g_config.camera_device << std::endl;
        return;
    }
    // Prefer MJPG over YUYV (lower USB bandwidth, more robust under EMI)
    cap.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc('M','J','P','G'));
    cap.set(cv::CAP_PROP_CONVERT_RGB, true);
    cap.set(cv::CAP_PROP_FRAME_WIDTH, g_config.camera_width);
    cap.set(cv::CAP_PROP_FRAME_HEIGHT, g_config.camera_height);
    cap.set(cv::CAP_PROP_FPS, g_config.camera_fps);

    // Verify camera is actually producing frames
    cv::Mat test_frame;
    bool got_frame = cap.read(test_frame);
    if (!got_frame) {
        std::cerr << "Camera opened but no frame (trying YUYV fallback)..." << std::endl;
        cap.release();
        cap.open(g_config.camera_device, cv::CAP_V4L2);
        cap.set(cv::CAP_PROP_FRAME_WIDTH, g_config.camera_width);
        cap.set(cv::CAP_PROP_FRAME_HEIGHT, g_config.camera_height);
        cap.set(cv::CAP_PROP_FPS, g_config.camera_fps);
        got_frame = cap.read(test_frame);
        if (!got_frame) {
            std::cerr << "Camera failed: no frames from " << g_config.camera_device << std::endl;
            return;
        }
    }
    std::cout << "Camera opened: " << g_config.camera_device
              << " (" << test_frame.cols << "x" << test_frame.rows << ")" << std::endl;

    cv::Mat frame;
    int frame_count = 0;
    auto t_start = std::chrono::steady_clock::now();

    // Temporal smoothing
    std::vector<double> prev_inv;
    double smooth_alpha = 0.5;

    while (g_running) {
        if (!cap.read(frame) || frame.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        auto t0 = std::chrono::steady_clock::now();

        std::vector<double> depth_inv;
        if (!model.infer(frame, depth_inv)) {
            continue;
        }

        auto t1 = std::chrono::steady_clock::now();
        double infer_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

        // Temporal smoothing
        if (!prev_inv.empty() && prev_inv.size() == depth_inv.size()) {
            for (size_t i = 0; i < depth_inv.size(); i++) {
                depth_inv[i] = smooth_alpha * depth_inv[i] + (1 - smooth_alpha) * prev_inv[i];
            }
        }
        prev_inv = depth_inv;

        // Determine output H, W from model
        int H = model.output_h;
        int W = model.output_w;

        cv::Mat depth_map;
        std::vector<float> points;
        process_depth(depth_inv, H, W, depth_map, points);

        // Update globals
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            frame.copyTo(g_frame);
            depth_map.copyTo(g_depth_map);
            g_points = std::move(points);
            g_stats.infer_time_ms = infer_ms;
            g_stats.point_count = (int)(g_points.size() / 3);
            if (!depth_inv.empty()) {
                g_stats.depth_min = *std::min_element(depth_inv.begin(), depth_inv.end());
                g_stats.depth_max = *std::max_element(depth_inv.begin(), depth_inv.end());
            }
        }

        // FPS
        frame_count++;
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - t_start).count();
        if (elapsed > 2.0) {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_stats.fps = frame_count / elapsed;
            frame_count = 0;
            t_start = now;
        }
    }
}

// ============================================================================
// Minimal HTTP Server
// ============================================================================

static std::string url_decode(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size()) {
            int v;
            sscanf(s.c_str() + i + 1, "%2x", &v);
            out += (char)v;
            i += 2;
        } else if (s[i] == '+') {
            out += ' ';
        } else {
            out += s[i];
        }
    }
    return out;
}

static std::string get_content_type(const std::string& path) {
    if (path.find(".html") != std::string::npos) return "text/html; charset=utf-8";
    if (path.find(".css") != std::string::npos) return "text/css";
    if (path.find(".js") != std::string::npos) return "application/javascript";
    if (path.find(".json") != std::string::npos) return "application/json";
    if (path.find(".png") != std::string::npos) return "image/png";
    if (path.find(".jpg") != std::string::npos) return "image/jpeg";
    return "text/plain";
}

static void send_response(int fd, int code, const std::string& ctype, const std::string& body) {
    std::string status;
    switch (code) {
        case 200: status = "200 OK"; break;
        case 404: status = "404 Not Found"; break;
        default: status = std::to_string(code); break;
    }
    std::ostringstream ss;
    ss << "HTTP/1.1 " << status << "\r\n"
       << "Content-Type: " << ctype << "\r\n"
       << "Content-Length: " << body.size() << "\r\n"
       << "Access-Control-Allow-Origin: *\r\n"
       << "Connection: close\r\n"
       << "\r\n"
       << body;
    std::string data = ss.str();
    write(fd, data.c_str(), data.size());
}

static void send_mjpeg_stream(int fd) {
    // Send multipart MJPEG headers
    std::string header = "HTTP/1.1 200 OK\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
        "Cache-Control: no-cache\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "\r\n";
    write(fd, header.c_str(), header.size());

    while (g_running) {
        cv::Mat frame, depth;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!g_frame.empty()) g_frame.copyTo(frame);
            if (!g_depth_map.empty()) g_depth_map.copyTo(depth);
        }

        if (frame.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(33));
            continue;
        }

        cv::Mat combined;
        if (!depth.empty()) {
            cv::Mat depth_norm, depth_u8, depth_color;
            cv::normalize(depth, depth_norm, 0, 255, cv::NORM_MINMAX);
            depth_norm.convertTo(depth_u8, CV_8U);
            depth_u8 = 255 - depth_u8;  // warm=near, cool=far
            cv::applyColorMap(depth_u8, depth_color, cv::COLORMAP_TURBO);
            cv::Mat depth_resized;
            cv::resize(depth_color, depth_resized, frame.size());
            cv::hconcat(frame, depth_resized, combined);
        } else {
            combined = frame;
        }

        std::vector<uchar> jpeg;
        cv::imencode(".jpg", combined, jpeg, {cv::IMWRITE_JPEG_QUALITY, 75});

        std::string part = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                         + std::to_string(jpeg.size()) + "\r\n\r\n";
        write(fd, part.c_str(), part.size());
        write(fd, jpeg.data(), jpeg.size());
        write(fd, "\r\n", 2);

        std::this_thread::sleep_for(std::chrono::milliseconds(33));
    }
}

// HTML template — loaded from file at runtime, fallback to minimal embedded version
static std::string g_html_template;

static const char* MINIMAL_HTML = R"HTML(
<!DOCTYPE html><html><head><title>MiDaS Web Demo</title></head>
<body style="background:#1a1a2e;color:#eee;font-family:sans-serif;padding:2rem;">
<h1>MiDaS Web Demo (C++)</h1>
<img src="/api/stream" style="max-width:100%;">
<p>Full UI at <a href="index.html" style="color:#53d8fb;">index.html</a></p>
</body></html>
)HTML";

static bool load_html_template(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    g_html_template = ss.str();
    return !g_html_template.empty();
}

// HTML template pointer — set in main()

static std::string json_escape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '"') out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else out += c;
    }
    return out;
}

static void handle_request(int fd) {
    char buf[8192];
    int n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';

    // Parse request line
    char method[16], path[512], ver[16];
    sscanf(buf, "%15s %511s %15s", method, path, ver);

    std::string s_method(method);
    std::string s_path(path);

    // Find body (after \r\n\r\n)
    std::string body;
    char* body_start = strstr(buf, "\r\n\r\n");
    if (body_start) {
        body = std::string(body_start + 4);
    }

    // Route handling
    if (s_path == "/" || s_path == "/index.html") {
        send_response(fd, 200, "text/html; charset=utf-8",
            g_html_template.empty() ? MINIMAL_HTML : g_html_template);
    }
    else if (s_path == "/api/stream") {
        send_mjpeg_stream(fd);
    }
    else if (s_path == "/api/params" && s_method == "GET") {
        std::ostringstream js;
        js << "{"
           << "\"model_path\":\"" << json_escape(g_config.model_path) << "\","
           << "\"camera_device\":\"" << json_escape(g_config.camera_device) << "\","
           << "\"camera_width\":" << g_config.camera_width << ","
           << "\"camera_height\":" << g_config.camera_height << ","
           << "\"camera_fps\":" << g_config.camera_fps << ","
           << "\"fov_h\":" << g_config.fov_h << ","
           << "\"fov_v\":" << g_config.fov_v << ","
           << "\"camera_x\":" << g_config.camera_x << ","
           << "\"camera_y\":" << g_config.camera_y << ","
           << "\"camera_z\":" << g_config.camera_z << ","
           << "\"camera_pitch\":" << g_config.camera_pitch << ","
           << "\"min_depth\":" << g_config.min_depth << ","
           << "\"max_depth\":" << g_config.max_depth << ","
           << "\"ground_height_threshold\":" << g_config.ground_height_threshold << ","
           << "\"point_stride\":" << g_config.point_stride
           << "}";
        send_response(fd, 200, "application/json", js.str());
    }
    else if (s_path == "/api/params" && s_method == "POST") {
        // Parse JSON body: {"key": value, ...}
        // Simple parser for flat key-value pairs
        auto set_double = [&](const std::string& key, const std::string& val) {
            double v = std::stod(val);
            if (key == "fov_h") g_config.fov_h = v;
            else if (key == "fov_v") g_config.fov_v = v;
            else if (key == "camera_x") g_config.camera_x = v;
            else if (key == "camera_y") g_config.camera_y = v;
            else if (key == "camera_z") g_config.camera_z = v;
            else if (key == "camera_pitch") g_config.camera_pitch = v;
            else if (key == "min_depth") g_config.min_depth = v;
            else if (key == "max_depth") g_config.max_depth = v;
            else if (key == "ground_height_threshold") g_config.ground_height_threshold = v;
            else if (key == "point_stride") g_config.point_stride = (int)v;
        };

        // Extract key-value pairs from JSON
        size_t pos = 0;
        while ((pos = body.find('"', pos)) != std::string::npos) {
            size_t key_start = pos + 1;
            size_t key_end = body.find('"', key_start);
            if (key_end == std::string::npos) break;
            std::string key = body.substr(key_start, key_end - key_start);

            size_t colon = body.find(':', key_end);
            if (colon == std::string::npos) break;

            // Find value (number or string)
            size_t val_start = body.find_first_not_of(" \t\n\r", colon + 1);
            if (val_start == std::string::npos) break;

            std::string val;
            if (body[val_start] == '"') {
                size_t val_end = body.find('"', val_start + 1);
                val = body.substr(val_start + 1, val_end - val_start - 1);
            } else {
                size_t val_end = body.find_first_of(",}\n\r", val_start);
                val = body.substr(val_start, val_end - val_start);
                // Trim whitespace
                while (!val.empty() && (val.back() == ' ' || val.back() == '\t'))
                    val.pop_back();
            }

            try { set_double(key, val); } catch (...) {}
            pos = val_start + 1;
        }
        send_response(fd, 200, "application/json", "{\"success\":true}");
    }
    else if (s_path == "/api/save" && s_method == "POST") {
        // Save config to YAML
        std::ofstream out(g_config.config_path);
        if (out.is_open()) {
            auto now = std::chrono::system_clock::now();
            auto tt = std::chrono::system_clock::to_time_t(now);
            char tbuf[64];
            strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", localtime(&tt));

            out << "# MiDaS Depth Navigation Parameters — RDK X5\n"
                << "# Calibrated via C++ Web Tool: " << tbuf << "\n\n"
                << "midas_depth:\n"
                << "  ros__parameters:\n"
                << "    model_path: \"" << g_config.model_path << "\"\n"
                << "    camera_device: \"" << g_config.camera_device << "\"\n"
                << "    camera_width: " << g_config.camera_width << "\n"
                << "    camera_height: " << g_config.camera_height << "\n"
                << "    camera_fps: " << g_config.camera_fps << "\n"
                << "    frame_id: \"camera_link\"\n"
                << "    base_frame_id: \"base_link\"\n"
                << "    fov_h: " << g_config.fov_h << "\n"
                << "    fov_v: " << g_config.fov_v << "\n"
                << "    camera_x: " << g_config.camera_x << "\n"
                << "    camera_y: " << g_config.camera_y << "\n"
                << "    camera_z: " << g_config.camera_z << "\n"
                << "    camera_pitch: " << g_config.camera_pitch << "\n"
                << "    min_depth: " << g_config.min_depth << "\n"
                << "    max_depth: " << g_config.max_depth << "\n"
                << "    ground_height_threshold: " << g_config.ground_height_threshold << "\n"
                << "    point_stride: " << g_config.point_stride << "\n"
                << "    publish_rate: 20.0\n";
            out.close();
            std::cout << "Config saved to " << g_config.config_path << std::endl;
            send_response(fd, 200, "application/json", "{\"success\":true}");
        } else {
            send_response(fd, 200, "application/json", "{\"success\":false,\"error\":\"Cannot open file\"}");
        }
    }
    else if (s_path == "/api/stats") {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::ostringstream js;
        js << "{\"fps\":" << g_stats.fps
           << ",\"infer_time\":" << g_stats.infer_time_ms
           << ",\"point_count\":" << g_stats.point_count
           << ",\"depth_range\":[" << g_stats.depth_min << "," << g_stats.depth_max << "]}";
        send_response(fd, 200, "application/json", js.str());
    }
    else if (s_path == "/api/pointcloud") {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::ostringstream js;
        js << "{\"points\":[";
        for (size_t i = 0; i < g_points.size(); i += 3) {
            if (i > 0) js << ",";
            js << "[" << g_points[i] << "," << g_points[i+1] << "," << g_points[i+2] << "]";
        }
        js << "]}";
        send_response(fd, 200, "application/json", js.str());
    }
    else if (s_path == "/api/snapshot") {
        cv::Mat frame;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!g_frame.empty()) g_frame.copyTo(frame);
        }
        if (frame.empty()) {
            send_response(fd, 404, "application/json", "{\"error\":\"No frame\"}");
        } else {
            std::vector<uchar> jpeg;
            cv::imencode(".jpg", frame, jpeg, {cv::IMWRITE_JPEG_QUALITY, 95});
            std::string header = "HTTP/1.1 200 OK\r\n"
                "Content-Type: image/jpeg\r\n"
                "Content-Length: " + std::to_string(jpeg.size()) + "\r\n"
                "Access-Control-Allow-Origin: *\r\n"
                "Connection: close\r\n\r\n";
            write(fd, header.c_str(), header.size());
            write(fd, jpeg.data(), jpeg.size());
        }
    }
    else if (s_path == "/api/reset" && s_method == "POST") {
        g_config.fov_h = 73.7; g_config.fov_v = 55.3;
        g_config.camera_x = 0.11; g_config.camera_y = 0.0;
        g_config.camera_z = 0.72; g_config.camera_pitch = 0.0;
        g_config.min_depth = 0.5; g_config.max_depth = 3.5;
        g_config.ground_height_threshold = 0.25; g_config.point_stride = 6;
        send_response(fd, 200, "application/json", "{\"success\":true}");
    }
    else {
        send_response(fd, 404, "text/plain", "Not Found");
    }
}

void http_server_thread(int port) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return;
    }

    listen(server_fd, 16);
    std::cout << "HTTP server listening on port " << port << std::endl;

    while (g_running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) continue;

        // Handle in detached thread (simple approach)
        std::thread([client_fd]() {
            handle_request(client_fd);
            close(client_fd);
        }).detach();
    }

    close(server_fd);
}

// ============================================================================
// Main
// ============================================================================

static void signal_handler(int sig) {
    (void)sig;
    std::cout << "\nShutting down..." << std::endl;
    g_running = false;
}

int main(int argc, char** argv) {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Parse command line args
    for (int i = 1; i < argc; i++) {
        std::string arg(argv[i]);
        if (arg == "--port" && i + 1 < argc) g_config.port = atoi(argv[++i]);
        else if (arg == "--model" && i + 1 < argc) g_config.model_path = argv[++i];
        else if (arg == "--camera" && i + 1 < argc) g_config.camera_device = argv[++i];
        else if (arg == "--config" && i + 1 < argc) g_config.config_path = argv[++i];
        else if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: " << argv[0] << " [OPTIONS]\n"
                      << "  --port N       HTTP port (default: 8080)\n"
                      << "  --model PATH   BPU model path\n"
                      << "  --camera DEV   Camera device (default: /dev/video0)\n"
                      << "  --config PATH  Config YAML path\n";
            return 0;
        }
    }

    std::cout << "========================================\n"
              << "  MiDaS Web Demo (C++)\n"
              << "========================================\n"
              << "  Model:  " << g_config.model_path << "\n"
              << "  Camera: " << g_config.camera_device << "\n"
              << "  Port:   " << g_config.port << "\n"
              << "========================================\n" << std::endl;

    // Load HTML template
    // Try: same dir as executable, then config dir, then hardcoded path
    std::string exe_dir = ".";
    {
        char buf[512];
        ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf)-1);
        if (len > 0) {
            buf[len] = '\0';
            char* slash = strrchr(buf, '/');
            if (slash) { *slash = '\0'; exe_dir = buf; }
        }
    }
    std::vector<std::string> html_paths = {
        exe_dir + "/index.html",
        "/path/to/midas_nav_alt/web_demo/index.html",
    };
    bool html_loaded = false;
    for (const auto& p : html_paths) {
        if (load_html_template(p)) {
            std::cout << "HTML template loaded: " << p
                      << " (" << g_html_template.size() << " bytes)" << std::endl;
            html_loaded = true;
            break;
        }
    }
    if (!html_loaded) {
        std::cout << "WARNING: HTML template not found, using minimal fallback" << std::endl;
    }

    // Start inference thread
    std::thread infer_thread(inference_thread_func);

    // Start HTTP server (blocks)
    http_server_thread(g_config.port);

    // Cleanup
    g_running = false;
    if (infer_thread.joinable()) infer_thread.join();

    return 0;
}
