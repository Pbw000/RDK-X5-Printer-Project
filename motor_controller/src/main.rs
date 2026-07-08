use futures::{Stream, StreamExt};
use r2r::QosProfile;
use r2r::geometry_msgs::msg::Twist;
use r2r::sensor_msgs::msg::LaserScan;
use ros_resolver::explorer::{Explorer, ScanData, SharedPose};
use ros_resolver::ros_adoptor::{DiffDrive, MotorInfo};
use ros_resolver::{FrameParser, MotorCtrl, MotorMessage, SingleMotorCtrl};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task;
use tokio_serial::{SerialPortBuilderExt, SerialStream};

use ros_resolver::ros_adoptor::BaseController;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let explore_mode = args.contains(&"--explore".to_string());

    if explore_mode {
        println!("ROS Resolver starting (explore mode)...");
    } else {
        println!("ROS Resolver starting...");
    }

    let port = tokio_serial::new("/dev/ttyS1", 115200).open_native_async()?;
    println!("Serial port opened at /dev/ttyS1, 115200 baud");

    let (reader, writer) = tokio::io::split(port);
    let (command_tx, command_rx) = mpsc::channel::<MotorCtrl>(32);
    let (message_tx, message_rx) = mpsc::channel::<MotorMessage>(32);

    let receive_handle = task::spawn(receive_task(reader, message_tx));
    let send_handle = task::spawn(send_task(writer, command_rx));

    let (controller, cmd_stream) = BaseController::init(0.06, 0.5, 768.0, 25.0)?;

    if explore_mode {
        run_explore_mode(controller, command_tx.clone(), message_rx).await;
    } else {
        run_normal_mode(
            controller,
            command_tx.clone(),
            message_rx,
            cmd_stream,
            receive_handle,
            send_handle,
        )
        .await;
    }

    println!("ROS Resolver shutting down...");
    Ok(())
}

async fn run_explore_mode(
    mut controller: BaseController,
    command_tx: mpsc::Sender<MotorCtrl>,
    mut message_rx: mpsc::Receiver<MotorMessage>,
) {
    let drive = controller.driver();
    let (scan_tx, scan_rx) = mpsc::channel::<ScanData>(5);
    let shared_pose = Arc::new(Mutex::new(SharedPose::default()));
    let explorer = Explorer::new(drive, command_tx.clone(), scan_rx, shared_pose.clone());

    let explore_handle = task::spawn(explorer.run());

    let shared_pose_for_odom = shared_pose.clone();
    let odom_handle = task::spawn(async move {
        while let Some(message) = message_rx.recv().await {
            match message {
                MotorMessage::MotorInfo {
                    motor_0_velocity,
                    motor_1_velocity,
                    motor_0_position,
                    motor_1_position,
                    imu_data,
                } => {
                    controller.spin();
                    if let Ok(pose) = controller.push_data(
                        &MotorInfo {
                            motor_0_velocity,
                            motor_1_velocity,
                            motor_0_position,
                            motor_1_position,
                        },
                        &imu_data,
                    ) {
                        if let Ok(mut sp) = shared_pose_for_odom.lock() {
                            sp.x = pose.x;
                            sp.y = pose.y;
                            sp.theta = pose.theta;
                        }
                    }
                }
                MotorMessage::SystemHello => {
                    if let Ok(bytes) = MotorMessage::SystemReady.to_bytes() {
                        println!("Would send SystemReady: {:?}", bytes);
                    }
                }
                _ => {}
            }
        }
    });

    let scan_handle = {
        let ctx = r2r::Context::create().expect("ctx");
        let mut node = r2r::Node::create(ctx, "explorer_scan", "").expect("node");
        let mut scan_stream = node
            .subscribe::<LaserScan>("/scan", QosProfile::default())
            .expect("subscribe");

        task::spawn(async move {
            loop {
                if let Some(scan) = scan_stream.next().await {
                    let scan_data = ScanData {
                        ranges: scan.ranges,
                        angle_min: scan.angle_min,
                        angle_increment: scan.angle_increment,
                        range_min: scan.range_min,
                        range_max: scan.range_max,
                    };
                    let _ = scan_tx.send(scan_data).await;
                }
                node.spin_once(Duration::ZERO);
            }
        })
    };

    tokio::select! {
        result = explore_handle => {
            if let Err(e) = result { eprintln!("Explorer failed: {}", e); }
        }
        _ = odom_handle => { eprintln!("Odom task ended"); }
        _ = scan_handle => { eprintln!("Scan task ended"); }
        _ = tokio::signal::ctrl_c() => {
            println!("Shutdown signal received, sending emergency halt...");
            let _ = command_tx.send(MotorCtrl::Motor0(SingleMotorCtrl::Stop)).await;
            let _ = command_tx.send(MotorCtrl::Motor1(SingleMotorCtrl::Stop)).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

async fn run_normal_mode(
    controller: BaseController,
    command_tx: mpsc::Sender<MotorCtrl>,
    message_rx: mpsc::Receiver<MotorMessage>,
    cmd_stream: impl Stream<Item = Twist> + Send + Unpin,
    receive_handle: task::JoinHandle<Result<(), Box<dyn std::error::Error + Send + Sync>>>,
    send_handle: task::JoinHandle<Result<(), Box<dyn std::error::Error + Send + Sync>>>,
) {
    let driver = controller.driver();
    let stop_tx = command_tx.clone();
    tokio::select! {
        result = motor_ctrl_task(command_tx, driver, cmd_stream) => {
            if let Err(e) = result { eprintln!("Motor control task failed: {}", e); }
        }
        result = process_task(message_rx, controller) => {
            if let Err(e) = result { eprintln!("Process task failed: {}", e); }
        }
        result = receive_handle => {
            if let Err(e) = result { eprintln!("Receive task failed: {}", e); }
        }
        result = send_handle => {
            if let Err(e) = result { eprintln!("Send task failed: {}", e); }
        }
        _ = tokio::signal::ctrl_c() => {
            println!("Shutdown signal received, sending emergency halt...");
            let _ = stop_tx.send(MotorCtrl::Motor0(SingleMotorCtrl::Stop)).await;
            let _ = stop_tx.send(MotorCtrl::Motor1(SingleMotorCtrl::Stop)).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

async fn motor_ctrl_task(
    ctrl_tx: mpsc::Sender<MotorCtrl>,
    driver: DiffDrive,
    mut cmd_stream: impl Stream<Item = Twist> + Send + Unpin,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    ctrl_tx
        .send(MotorCtrl::MotorAll(
            ros_resolver::SingleMotorCtrl::HardWareInit,
        ))
        .await?;
    tokio::time::sleep(Duration::from_secs(2)).await;
    loop {
        tokio::select! {
            cmd = cmd_stream.next() => {
                if let Some(cmd) = cmd {
                    let (v1, v2) = driver.encode_cmd(&cmd);
                    ctrl_tx.send(MotorCtrl::Motor0(ros_resolver::SingleMotorCtrl::SetTargetVelocity { velocity: -v1 })).await?;
                    ctrl_tx.send(MotorCtrl::Motor1(ros_resolver::SingleMotorCtrl::SetTargetVelocity { velocity: -v2 })).await?;
                }else{
                    break;
                }
            },
            _ = tokio::time::sleep(Duration::from_millis(100)) => {
                ctrl_tx.send(MotorCtrl::Heartbeat).await?;
            }
        }
    }
    Ok(())
}

async fn receive_task(
    mut reader: tokio::io::ReadHalf<SerialStream>,
    message_tx: mpsc::Sender<MotorMessage>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut parser = FrameParser::new(&[b'@', b'#', b'$'], &[b'\n', b'\r', b'\0']);
    let mut byte_buf = [0u8; 1];
    println!("Receive task started");
    loop {
        match reader.read_exact(&mut byte_buf).await {
            Ok(_) => {
                if let Some(message) = parser.process_byte(byte_buf[0]) {
                    if let Err(e) = message_tx.send(message).await {
                        eprintln!("Failed to send message: {}", e);
                        return Ok(());
                    }
                }
                if parser.buffer_size() > 4096 {
                    parser.reset();
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                break;
            }
            Err(e) => {
                eprintln!("Read error: {}", e);
                break;
            }
        }
    }
    Ok(())
}

async fn send_task(
    mut writer: tokio::io::WriteHalf<SerialStream>,
    mut command_rx: mpsc::Receiver<MotorCtrl>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("Send task started");
    while let Some(command) = command_rx.recv().await {
        match command.to_bytes() {
            Ok(bytes) => {
                if let Err(e) = writer.write_all(&bytes).await {
                    eprintln!("Write error: {}", e);
                    break;
                }
                if let Err(e) = writer.flush().await {
                    eprintln!("Flush error: {}", e);
                    break;
                }
            }
            Err(e) => {
                eprintln!("Serialize error: {}", e);
            }
        }
    }
    Ok(())
}

async fn process_task(
    mut message_rx: mpsc::Receiver<MotorMessage>,
    mut controller: BaseController,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("Process task started (normal mode)");
    while let Some(message) = message_rx.recv().await {
        match message {
            MotorMessage::MotorInfo {
                motor_0_velocity,
                motor_1_velocity,
                motor_0_position,
                motor_1_position,
                imu_data,
            } => {
                controller.spin();
                let _ = controller.push_data(
                    &MotorInfo {
                        motor_0_velocity,
                        motor_1_velocity,
                        motor_0_position,
                        motor_1_position,
                    },
                    &imu_data,
                );
            }
            MotorMessage::SystemHello => {
                if let Ok(bytes) = MotorMessage::SystemReady.to_bytes() {
                    println!("Would send SystemReady: {:?}", bytes);
                }
            }
            _ => {}
        }
    }
    Ok(())
}
