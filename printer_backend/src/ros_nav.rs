use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::models::map_data::{MapSnapshot, store_map_json};
use futures::StreamExt;
use r2r::QosProfile;
use r2r::builtin_interfaces::msg::Time;
use r2r::geometry_msgs::msg::PoseWithCovarianceStamped;
use r2r::geometry_msgs::msg::{Point, Pose, PoseStamped, Quaternion, TransformStamped};
use r2r::nav_msgs::msg::{OccupancyGrid, Odometry};
use r2r::nav2_msgs::action::{ComputePathToPose, NavigateToPose};
use r2r::std_msgs::msg::Header;
use r2r::tf2_msgs::msg::TFMessage;
use std::sync::LazyLock;
use tokio::sync::{RwLock, watch};

/// Maximum number of destinations supported.
pub const MAX_NODES: usize = 16;

/// Path distance cache (async-safe, stack-allocated backing array).
///
/// Index `0..MAX_NODES-1` = destination indices.
/// Index `MAX_NODES` = current robot position.
/// Value = path distance in metres; `f64::INFINITY` if not yet computed.
pub static PATH_CACHE: LazyLock<RwLock<[[f64; MAX_NODES + 1]; MAX_NODES + 1]>> =
    LazyLock::new(|| RwLock::new([[f64::INFINITY; MAX_NODES + 1]; MAX_NODES + 1]));

/// 2D pose / transform.
#[derive(Debug, Clone, Copy, Default, serde::Serialize)]
pub struct Pose2D {
    pub x: f64,
    pub y: f64,
    pub theta: f64,
}

/// Compose two 2D transforms: result = a * b.
fn compose_2d(a: &Pose2D, b: &Pose2D) -> Pose2D {
    let (s, c) = a.theta.sin_cos();
    Pose2D {
        x: a.x + c * b.x - s * b.y,
        y: a.y + s * b.x + c * b.y,
        theta: a.theta + b.theta,
    }
}

/// Extract a 2D pose from a ROS TransformStamped.
fn tf_to_pose2d(tf: &TransformStamped) -> Pose2D {
    let q = &tf.transform.rotation;
    let siny_cosp = 2.0 * (q.w * q.z + q.x * q.y);
    let cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
    Pose2D {
        x: tf.transform.translation.x,
        y: tf.transform.translation.y,
        theta: siny_cosp.atan2(cosy_cosp),
    }
}

/// ROS 2 navigation interface.
///
/// Wraps an r2r node running on a dedicated spin-thread, providing:
/// - Current robot pose from `/odom`
/// - Path distance computation via `nav2_msgs/ComputePathToPose`
/// - Navigation via `nav2_msgs/NavigateToPose`
pub struct RosNav {
    /// Composed SLAM-estimated pose: map → base_link.
    current_pose_rx: watch::Receiver<Pose2D>,
    path_client: r2r::ActionClient<ComputePathToPose::Action>,
    nav_client: r2r::ActionClient<NavigateToPose::Action>,
}


impl RosNav {
    /// Initialize the ROS 2 navigation node.
    ///
    /// Spawns a background thread that spins the r2r node and a tokio task
    /// that continuously tracks odometry.
    pub fn init() -> Result<Arc<Self>, Box<dyn std::error::Error + Send + Sync>> {
        let ctx = r2r::Context::create()?;
        let mut node = r2r::Node::create(ctx, "printer_nav", "")?;

        // ---- watch channel for the composed map→base_link pose ----
        let (pose_tx, current_pose_rx) = watch::channel(Pose2D::default());

        // ---- /odom subscriber ----
        let mut odom_sub = node.subscribe::<Odometry>("/odom", QosProfile::default())?;

        // ---- /tf subscriber (for map→odom correction from SLAM) ----
        let map_to_odom = Arc::new(Mutex::new(Pose2D::default()));
        let odom_to_base = Arc::new(Mutex::new(Pose2D::default()));
        let m2o_tf = map_to_odom.clone();
        let o2b_tf = odom_to_base.clone();
        let pose_tf = pose_tx.clone();
        let mut tf_sub = node.subscribe::<TFMessage>("/tf", QosProfile::default())?;
        tracing::info!("Subscribed to /tf");

        // ---- /map subscriber (transient_local to match map_server) ----
        let map_qos = QosProfile::default().transient_local();
        let mut map_sub = node.subscribe::<OccupancyGrid>("/map", map_qos)?;
        tracing::info!("Subscribed to /map (nav_msgs/OccupancyGrid, transient_local)");

        // ---- /amcl_pose subscriber ----
        // AMCL publishes the SLAM-estimated pose directly.
        // When this topic is available it overrides TF composition.
        let amcl_qos = QosProfile::default().transient_local();
        let mut amcl_sub = node.subscribe::<PoseWithCovarianceStamped>("/amcl_pose", amcl_qos)?;
        tracing::info!("Subscribed to /amcl_pose (transient_local)");

        // ---- action clients (created before node is moved) ----
        let path_client =
            node.create_action_client::<ComputePathToPose::Action>("/compute_path_to_pose")?;
        let nav_client =
            node.create_action_client::<NavigateToPose::Action>("/navigate_to_pose")?;

        // ---- spin the node on a dedicated OS thread ----
        std::thread::Builder::new()
            .name("ros_nav_spin".into())
            .spawn(move || {
                loop {
                    node.spin_once(Duration::from_millis(10));
                }
            })?;

        // ---- map tracking task (closes after first frame) ----
        tokio::spawn(async move {
            if let Some(grid) = map_sub.next().await {
                let snapshot = MapSnapshot::from_occupancy_grid(&grid);
                tracing::info!(
                    width = snapshot.width,
                    height = snapshot.height,
                    resolution = snapshot.resolution,
                    "First /map OccupancyGrid received"
                );
                let json = serde_json::to_string(&snapshot).unwrap_or_default();
                store_map_json(json);
            }
        });

        // ---- TF tracking task (map→odom from SLAM) ----
        tokio::spawn(async move {
            let mut last_log = std::time::Instant::now();
            while let Some(tf_msg) = tf_sub.next().await {
                for tf in &tf_msg.transforms {
                    if tf.header.frame_id == "map" && tf.child_frame_id == "odom" {
                        let new_m2o = tf_to_pose2d(tf);
                        *m2o_tf.lock().unwrap() = new_m2o;
                        // Compose: map→base = map→odom * odom→base
                        let o2b_val = *o2b_tf.lock().unwrap();
                        let composed = compose_2d(&new_m2o, &o2b_val);
                        let _ = pose_tf.send(composed);
                        if last_log.elapsed() >= std::time::Duration::from_secs(5) {
                            tracing::debug!(
                                map_to_odom_x = format_args!("{:.3}", new_m2o.x),
                                map_to_odom_y = format_args!("{:.3}", new_m2o.y),
                                composed_x = format_args!("{:.3}", composed.x),
                                composed_y = format_args!("{:.3}", composed.y),
                                "TF map→odom updated, composed pose"
                            );
                            last_log = std::time::Instant::now();
                        }
                    } else if tf.header.frame_id == "odom" && tf.child_frame_id == "base_link" {
                        let new_o2b = tf_to_pose2d(tf);
                        *o2b_tf.lock().unwrap() = new_o2b;
                    }
                }
            }
        });
        let m2o_odom = map_to_odom.clone();
        let o2b_odom = odom_to_base.clone();
        let pose_tx_odom = pose_tx.clone();
        tokio::spawn(async move {
            let mut last_log = std::time::Instant::now();
            while let Some(odom) = odom_sub.next().await {
                let q = &odom.pose.pose.orientation;
                let siny_cosp = 2.0 * (q.w * q.z + q.x * q.y);
                let cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
                let theta = siny_cosp.atan2(cosy_cosp);
                let o2b = Pose2D {
                    x: odom.pose.pose.position.x,
                    y: odom.pose.pose.position.y,
                    theta,
                };
                // Store odom→base_link
                *o2b_odom.lock().unwrap() = o2b;
                // Compose: map→base = map→odom * odom→base
                let m2o_val = *m2o_odom.lock().unwrap();
                let composed = compose_2d(&m2o_val, &o2b);
                let _ = pose_tx_odom.send(composed);
                if last_log.elapsed() >= std::time::Duration::from_secs(5) {
                    tracing::debug!(
                        odom_x = format_args!("{:.3}", o2b.x),
                        odom_y = format_args!("{:.3}", o2b.y),
                        odom_theta = format_args!("{:.3}", o2b.theta),
                        "Odom → base_link updated"
                    );
                    last_log = std::time::Instant::now();
                }
            }
        });

        // ---- AMCL pose tracking task ----
        // AMCL publishes the full SLAM-corrected pose (map→base_link).
        // When available, this is the most accurate pose source.
        tokio::spawn(async move {
            let mut last_log = std::time::Instant::now();
            while let Some(amcl_pose) = amcl_sub.next().await {
                let q = &amcl_pose.pose.pose.orientation;
                let siny_cosp = 2.0 * (q.w * q.z + q.x * q.y);
                let cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
                let theta = siny_cosp.atan2(cosy_cosp);
                let pose = Pose2D {
                    x: amcl_pose.pose.pose.position.x,
                    y: amcl_pose.pose.pose.position.y,
                    theta,
                };
                let _ = pose_tx.send(pose);
                // Throttled log: every 5 seconds
                if last_log.elapsed() >= std::time::Duration::from_secs(5) {
                    tracing::info!(
                        x = format_args!("{:.3}", pose.x),
                        y = format_args!("{:.3}", pose.y),
                        theta = format_args!("{:.3}", pose.theta),
                        "AMCL pose updated"
                    );
                    last_log = std::time::Instant::now();
                }
            }
        });

        Ok(Arc::new(Self {
            current_pose_rx,
            path_client,
            nav_client,
        }))
    }

    /// Block until both nav2 action servers are available (with timeout).
    pub async fn wait_for_servers(&self, timeout: Duration) -> Result<(), String> {
        let path_avail = r2r::Node::is_available(&self.path_client)
            .map_err(|e| format!("is_available (path): {}", e))?;
        let nav_avail = r2r::Node::is_available(&self.nav_client)
            .map_err(|e| format!("is_available (nav): {}", e))?;

        tokio::time::timeout(timeout, async {
            let _ = path_avail.await;
            let _ = nav_avail.await;
        })
        .await
        .map_err(|_| "Timeout waiting for nav2 action servers".to_string())
    }

    /// Current robot pose (fast, watch-based).
    pub fn current_pose(&self) -> Pose2D {
        *self.current_pose_rx.borrow()
    }

    /// Compute the planner-based path distance between two map poses.
    pub async fn compute_path_distance(
        &self,
        from: (f64, f64, f64),
        to: (f64, f64, f64),
    ) -> Result<f64, String> {
        tracing::debug!(
            from_x = format_args!("{:.3}", from.0),
            from_y = format_args!("{:.3}", from.1),
            to_x = format_args!("{:.3}", to.0),
            to_y = format_args!("{:.3}", to.1),
            "Computing path distance"
        );

        let goal_msg = ComputePathToPose::Goal {
            goal: make_pose_stamped(to.0, to.1, to.2),
            start: make_pose_stamped(from.0, from.1, from.2),
            planner_id: "GridBased".to_string(),
            use_start: true,
        };

        let (_goal_handle, result_future, _feedback) = self
            .path_client
            .send_goal_request(goal_msg)
            .map_err(|e| format!("send_goal_request: {}", e))?
            .await
            .map_err(|e| format!("Path goal rejected: {}", e))?;

        let (_status, result) = result_future
            .await
            .map_err(|e| format!("Path computation failed: {}", e))?;

        let path = result.path;
        if path.poses.is_empty() {
            tracing::warn!("No path found between points");
            return Err("No path found".into());
        }

        let mut total = 0.0;
        for w in path.poses.windows(2) {
            let dx = w[1].pose.position.x - w[0].pose.position.x;
            let dy = w[1].pose.position.y - w[0].pose.position.y;
            total += (dx * dx + dy * dy).sqrt();
        }
        tracing::debug!(
            distance = format_args!("{:.3}", total),
            waypoints = path.poses.len(),
            "Path distance computed"
        );
        Ok(total)
    }

    /// Send a NavigateToPose goal and wait until the robot arrives.
    pub async fn navigate_to(&self, x: f64, y: f64, yaw: f64) -> Result<(), String> {
        let cur = self.current_pose();
        tracing::info!(
            goal_x = format_args!("{:.3}", x),
            goal_y = format_args!("{:.3}", y),
            goal_yaw = format_args!("{:.3}", yaw),
            from_x = format_args!("{:.3}", cur.x),
            from_y = format_args!("{:.3}", cur.y),
            "NavigateToPose goal sent"
        );

        let goal_msg = NavigateToPose::Goal {
            pose: make_pose_stamped(x, y, yaw),
            behavior_tree: String::new(),
        };

        let (_goal_handle, result_future, _feedback) = self
            .nav_client
            .send_goal_request(goal_msg)
            .map_err(|e| format!("send_goal_request: {}", e))?
            .await
            .map_err(|e| format!("Nav goal rejected: {}", e))?;

        let (_status, _result) = result_future
            .await
            .map_err(|e| {
                tracing::error!(
                    goal_x = format_args!("{:.3}", x),
                    goal_y = format_args!("{:.3}", y),
                    err = %e,
                    "Navigation failed"
                );
                format!("Navigation failed: {}", e)
            })?;

        let arrived = self.current_pose();
        tracing::info!(
            goal_x = format_args!("{:.3}", x),
            goal_y = format_args!("{:.3}", y),
            arrived_x = format_args!("{:.3}", arrived.x),
            arrived_y = format_args!("{:.3}", arrived.y),
            "Navigation completed, robot arrived"
        );
        Ok(())
    }

    /// Refresh current-position to all-destination distances in PATH_CACHE.
    pub async fn refresh_dynamic_distances(&self, dest_coords: &[(f64, f64)]) {
        let cur = self.current_pose();
        let n = dest_coords.len().min(MAX_NODES);
        tracing::info!(
            current_x = format_args!("{:.3}", cur.x),
            current_y = format_args!("{:.3}", cur.y),
            num_destinations = n,
            "Refreshing dynamic path distances"
        );
        for j in 0..n {
            let from = (cur.x, cur.y, cur.theta);
            let to = (dest_coords[j].0, dest_coords[j].1, 0.0);
            match self.compute_path_distance(from, to).await {
                Ok(dist) => {
                    let mut c = PATH_CACHE.write().await;
                    c[MAX_NODES][j] = dist;
                    c[j][MAX_NODES] = dist;
                    tracing::debug!(
                        dest = j,
                        distance = format_args!("{:.3}", dist),
                        "Dynamic distance updated"
                    );
                }
                Err(e) => {
                    tracing::warn!(dest = j, err = %e, "dynamic path compute failed");
                }
            }
        }
    }

    /// Compute and cache all destination to destination distances (one-shot).
    pub async fn init_static_distances(&self, dest_coords: &[(f64, f64)]) {
        let n = dest_coords.len().min(MAX_NODES);
        for i in 0..n {
            for j in (i + 1)..n {
                let from = (dest_coords[i].0, dest_coords[i].1, 0.0);
                let to = (dest_coords[j].0, dest_coords[j].1, 0.0);
                match self.compute_path_distance(from, to).await {
                    Ok(dist) => {
                        let mut c = PATH_CACHE.write().await;
                        c[i][j] = dist;
                        c[j][i] = dist;
                    }
                    Err(e) => {
                        tracing::warn!(from = i, to = j, err = %e, "static path compute failed");
                    }
                }
            }
        }
    }
}

/// Spawn a background task that periodically refreshes the path cache.
pub fn spawn_cache_refresh(
    ros_nav: Arc<RosNav>,
    state: Arc<crate::models::AppState>,
    interval: Duration,
) {
    tokio::spawn(async move {
        // Wait for servers.
        if let Err(e) = ros_nav.wait_for_servers(Duration::from_secs(30)).await {
            tracing::error!(err = %e, "Cannot reach nav2 servers, cache refresh aborting");
            return;
        }

        // One-shot: compute all static dest to dest distances.
        let coords: Vec<(f64, f64)> = {
            let dests = state.jobs.lock().await;
            dests
                .destinations
                .iter()
                .take(MAX_NODES)
                .map(|d| (d.location.x_cord, d.location.y_cord))
                .collect()
        };
        ros_nav.init_static_distances(&coords).await;
        tracing::info!(n = coords.len(), "Static path cache initialized");

        // Periodic: refresh current-position to dest distances.
        loop {
            tokio::time::sleep(interval).await;
            let coords: Vec<(f64, f64)> = {
                let dests = state.jobs.lock().await;
                dests
                    .destinations
                    .iter()
                    .take(MAX_NODES)
                    .map(|d| (d.location.x_cord, d.location.y_cord))
                    .collect()
            };
            ros_nav.refresh_dynamic_distances(&coords).await;
        }
    });
}

/// Spawn a background task that continuously broadcasts the robot position
/// at a low rate (1 Hz) over the SSE channel. This runs independently of the
/// higher-rate (5 Hz) position stream that activates during navigation.
pub fn spawn_position_broadcast(
    ros_nav: Arc<RosNav>,
    sse_tx: tokio::sync::broadcast::Sender<Arc<String>>,
) {
    use crate::scheduler::OwnedPrinterEvent;

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_log = std::time::Instant::now();
        let mut broadcast_count: u64 = 0;
        loop {
            interval.tick().await;
            let pose = ros_nav.current_pose();
            broadcast_count += 1;
            let event = OwnedPrinterEvent::PositionUpdate {
                x: pose.x,
                y: pose.y,
                theta: pose.theta,
            };
            if let Ok(json) = serde_json::to_string(&event) {
                let _ = sse_tx.send(Arc::new(json));
            }
            // Log position every 10 seconds
            if last_log.elapsed() >= std::time::Duration::from_secs(10) {
                tracing::info!(
                    x = format_args!("{:.3}", pose.x),
                    y = format_args!("{:.3}", pose.y),
                    theta = format_args!("{:.3}", pose.theta),
                    broadcast_count,
                    "Position broadcast"
                );
                last_log = std::time::Instant::now();
            }
        }
    });
}

fn make_pose_stamped(x: f64, y: f64, yaw: f64) -> PoseStamped {
    PoseStamped {
        header: Header {
            stamp: Time { sec: 0, nanosec: 0 },
            frame_id: "map".to_string(),
        },
        pose: Pose {
            position: Point { x, y, z: 0.0 },
            orientation: Quaternion {
                x: 0.0,
                y: 0.0,
                z: (yaw / 2.0).sin(),
                w: (yaw / 2.0).cos(),
            },
        },
    }
}
