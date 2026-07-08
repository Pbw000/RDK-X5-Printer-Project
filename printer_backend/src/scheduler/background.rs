use std::sync::Arc;

use crate::{
    models::{AppState, FileState, printer_status::PrinterStatus},
    scheduler::{runner::PrinterExecutor, scheduler::Scheduler},
};

use super::{OwnedPrinterEvent, PrinterInfo};

pub async fn printing_task(state: Arc<AppState>, printer: PrinterExecutor, scheduler: Scheduler) {
    let send = |info: &PrinterInfo| {
        if let Ok(json_info) = serde_json::to_string(info) {
            let _ = state
                .channels
                .printer_info_channels
                .send(Arc::new(json_info));
        }
    };

    loop {
        state.printer_state.set_status(PrinterStatus::Idle);
        send(&PrinterInfo::Idle);
        tracing::info!("Printer status: Idle, waiting for jobs");
        state.printer_state.wait_for_status_change().await;
        tracing::info!("Background task woken up, checking for pending jobs");

        // Re-plan the full route via bitmask DP each time new jobs arrive.
        'printing_loop: loop {
            // ---- Step 1: plan the optimal route ----
            tracing::info!("Starting route planning...");
            let route_plan = {
                let jobs = state.jobs.lock().await;
                tracing::debug!(
                    destinations_count = jobs.destinations.len(),
                    "Checking destinations for pending jobs"
                );
                match scheduler.solve_route(&*jobs).await {
                    Ok(plan) => {
                        tracing::info!("Route planning succeeded");
                        plan
                    }
                    Err(e) => {
                        tracing::warn!(error = ?e, "Route planning failed");
                        send(&PrinterInfo::SchedulerError {
                            msg: &format!("Scheduling error: {:?}", e),
                        });
                        break 'printing_loop;
                    }
                }
            };

            let route = route_plan.route;
            tracing::info!(
                route = ?route,
                stops = route.len(),
                "Route selected: {} destination(s) planned",
                route.len()
            );

            // ---- Refresh navigation status inside the solver (already held locks) ----
            {
                let mut nav_status = state.navigation_status.write().await;
                *nav_status = route_plan.navigation_status;
                tracing::debug!("Updated navigation status");
            }

            let Some(next_idx) = route.into_iter().next() else {
                tracing::info!("No destinations in route, exiting printing loop");
                break 'printing_loop;
            };
            tracing::info!(next_destination_idx = next_idx, "Selected next destination");

            // ---- Step 2: drain jobs for the chosen destination ----
            let (next_pos, location_name, printing_jobs) = {
                let mut jobs = state.jobs.lock().await;
                let dest = &mut jobs.destinations[next_idx];
                let location_name = dest.name.clone();
                let to_print = std::mem::take(&mut dest.pending_jobs);
                tracing::info!(
                    destination_idx = next_idx,
                    location_name = %location_name,
                    jobs_drained = to_print.len(),
                    "Drained pending jobs from destination"
                );
                (dest.location, location_name, to_print)
            };

            let total_jobs = printing_jobs.len();
            if total_jobs == 0 {
                tracing::info!("No jobs to print at destination, continuing to next");
                break 'printing_loop;
            }

            // ---- Step 3: set status and announce ----
            tracing::info!(
                total_jobs = total_jobs,
                "Setting printer status to Moving"
            );
            state.printer_state.set_status(PrinterStatus::Moving);

            send(&PrinterInfo::BatchStarted {
                location_id: next_idx,
                location_name: &location_name,
                total_jobs,
            });
            tracing::info!(
                location_id = next_idx,
                location_name = %location_name,
                x = next_pos.x_cord,
                y = next_pos.y_cord,
                jobs_count = total_jobs,
                "Moving to location"
            );

            send(&PrinterInfo::MovingTo {
                position: next_pos,
                location_id: next_idx,
                location_name: &location_name,
            });

            // ---- Step 4: move (real NavigateToPose) + position stream + print ----
            tracing::info!("Starting movement and print tasks concurrently");
            let mut succeeded = 0usize;
            let mut failed = 0usize;

            let ros_nav = state.ros_nav.clone();
            let nav_dest = next_pos;
            let nav_loc_id = next_idx;
            let nav_state = state.clone();

            // Movement + position broadcasting at ~5 Hz
            let move_future = async move {
                tracing::info!(
                    target_x = nav_dest.x_cord,
                    target_y = nav_dest.y_cord,
                    "Starting navigation to destination"
                );
                let nav_handle = tokio::spawn({
                    let ros_nav = ros_nav.clone();
                    let state = nav_state.clone();
                    async move {
                        // Broadcast position at ~5 Hz while moving
                        let mut interval = tokio::time::interval(
                            std::time::Duration::from_millis(200),
                        );
                        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                        tracing::debug!("Position broadcasting task started (5 Hz)");
                        loop {
                            interval.tick().await;
                            let pose = ros_nav.current_pose();
                            let event = OwnedPrinterEvent::PositionUpdate {
                                x: pose.x,
                                y: pose.y,
                                theta: pose.theta,
                            };
                            if let Ok(json) = serde_json::to_string(&event) {
                                let _ = state.channels.printer_info_channels.send(Arc::new(json));
                            }
                        }
                    }
                });

                let result = ros_nav
                    .navigate_to(nav_dest.x_cord, nav_dest.y_cord, 0.0)
                    .await;

                // Stop broadcasting once navigation finishes
                nav_handle.abort();
                tracing::debug!("Position broadcasting task stopped");

                // Final position after arrival
                let pose = ros_nav.current_pose();
                tracing::info!(
                    final_x = pose.x,
                    final_y = pose.y,
                    final_theta = pose.theta,
                    "Navigation finished, final position"
                );
                let event = OwnedPrinterEvent::PositionUpdate {
                    x: pose.x,
                    y: pose.y,
                    theta: pose.theta,
                };
                if let Ok(json) = serde_json::to_string(&event) {
                    let _ = nav_state.channels.printer_info_channels.send(Arc::new(json));
                }

                result
            };

            tracing::info!(
                total_jobs = total_jobs,
                "Setting printer status to Printing"
            );
            state.printer_state.set_status(PrinterStatus::Printing {
                total: total_jobs as u32,
                processed: 0,
            });

            let print_future = async {
                tracing::info!(
                    total_jobs = total_jobs,
                    "Starting print job execution"
                );
                for (index, job) in printing_jobs.iter().enumerate() {
                    let file_id = job.file_id;
                    tracing::info!(
                        job_index = index,
                        total_jobs = total_jobs,
                        file_id = %file_id,
                        stored_name = %job.stored_name,
                        file_type = ?job.file_type,
                        "Processing print job"
                    );
                    
                    let Some(path) = job.file_path.to_str() else {
                        tracing::error!(
                            job_index = index,
                            file_path = ?job.file_path,
                            "Invalid file path, skipping job"
                        );
                        send(&PrinterInfo::PrintFailed {
                            msg: &format!("Invalid file path for job: {:?}", job.file_path),
                            location_id: next_idx,
                            store_name: &job.stored_name,
                        });
                        failed += 1;
                        continue;
                    };

                    state.file_states.insert(file_id, FileState::Printing);

                    send(&PrinterInfo::PrintStarted {
                        store_name: &job.stored_name,
                        location_id: next_idx,
                        job_index: index,
                        total_jobs,
                    });

                    tracing::info!(
                        job_index = index,
                        file_path = %path,
                        "Sending job to printer"
                    );
                    match printer.print_by_type(path, job.file_type) {
                        Ok(job_handle) => {
                            tracing::info!(
                                job_index = index,
                                "Print job submitted, waiting for completion"
                            );
                            job_handle.poll_wait().await;
                            tracing::info!(
                                job_index = index,
                                stored_name = %job.stored_name,
                                "Print job completed successfully"
                            );
                            send(&PrinterInfo::PrintComplete {
                                store_name: &job.stored_name,
                                location_id: next_idx,
                            });
                            succeeded += 1;
                            state.file_states.insert(file_id, FileState::WaitingForPickUp);
                            state.printer_state.set_status(PrinterStatus::Printing {
                                total: total_jobs as u32,
                                processed: (succeeded + failed) as u32,
                            });
                            tracing::debug!(
                                succeeded = succeeded,
                                failed = failed,
                                "Updated print progress"
                            );
                        }
                        Err(e) => {
                            tracing::error!(
                                job_index = index,
                                error = ?e,
                                file_type = ?job.file_type,
                                "Print job failed"
                            );
                            send(&PrinterInfo::PrintFailed {
                                msg: &format!("Failed to print {:?}: {:?}", job.file_type, e),
                                location_id: next_idx,
                                store_name: &job.stored_name,
                            });
                            failed += 1;
                            state.printer_state.set_status(PrinterStatus::Printing {
                                total: total_jobs as u32,
                                processed: (succeeded + failed) as u32,
                            });
                            tracing::debug!(
                                succeeded = succeeded,
                                failed = failed,
                                "Updated print progress after failure"
                            );
                        }
                    }
                }
                tracing::info!(
                    succeeded = succeeded,
                    failed = failed,
                    "All print jobs processed"
                );
            };

            // Run move and print concurrently. If movement fails, log it
            // but still attempt to print (the printer might already be at
            // the destination).
            tracing::info!("Waiting for movement and print tasks to complete");
            let (move_result, ()) = tokio::join!(move_future, print_future);
            tracing::info!("Movement and print tasks finished");

            if let Err(e) = move_result {
                send(&PrinterInfo::NavError {
                    msg: &e,
                    location_id: nav_loc_id,
                });
                tracing::error!(err = %e, loc = nav_loc_id, "Navigation failed");
            } else {
                tracing::info!(
                    location_id = nav_loc_id,
                    location_name = %location_name,
                    "ROS navigation completed, arrived at destination"
                );
                send(&PrinterInfo::MoveComplete {
                    location_id: nav_loc_id,
                });
            }

            // ---- Step 5: batch complete ----
            tracing::info!(
                location_id = next_idx,
                "Setting printer status to WaitingConfirmation"
            );
            state.printer_state.set_status(PrinterStatus::WaitingConfirmation);
            tracing::info!(
                location_id = next_idx,
                location_name = %location_name,
                succeeded = succeeded,
                failed = failed,
                "Batch complete, waiting for confirmation"
            );
            send(&PrinterInfo::BatchComplete {
                location_id: next_idx,
                location_name: &location_name,
                succeeded,
                failed,
            });

            // ---- Step 6: tick loop — send remaining every 5s, wait for confirm or timeout ----
            let timeout_secs: u64 = 120;
            let tick_interval = std::time::Duration::from_secs(5);
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
            let mut ticker = tokio::time::interval(tick_interval);
            ticker.tick().await; // skip the immediate first tick

            tracing::info!(
                loc = next_idx,
                timeout = timeout_secs,
                "Starting confirmation tick loop (5s interval, {}s timeout)",
                timeout_secs
            );

            loop {
                let remaining = deadline
                    .saturating_duration_since(tokio::time::Instant::now())
                    .as_secs();

                tracing::debug!(
                    remaining_secs = remaining,
                    "Sending confirmation tick"
                );
                send(&PrinterInfo::ConfirmTick {
                    remaining_secs: remaining,
                });

                if remaining == 0 {
                    tracing::warn!(
                        loc = next_idx,
                        timeout = timeout_secs,
                        "Confirmation timed out after {}s, auto-continuing",
                        timeout_secs
                    );
                    break;
                }

                tokio::select! {
                    _ = ticker.tick() => {
                        tracing::trace!(remaining_secs = remaining, "Tick interval elapsed, sending next tick");
                    }
                    _ = state.printer_state.wait_for_completion() => {
                        tracing::info!(
                            loc = next_idx,
                            remaining_secs = remaining,
                            "User confirmed batch completion, continuing"
                        );
                        break;
                    }
                }
            }

            // Files have either been picked up or timed out; remove them from state.
            tracing::info!(
                location_id = next_idx,
                jobs_count = printing_jobs.len(),
                "Cleaning up completed jobs from state"
            );
            for job in &printing_jobs {
                tracing::debug!(
                    file_id = %job.file_id,
                    stored_name = %job.stored_name,
                    "Removing job from file states"
                );
                state.file_states.remove(&job.file_id);
            }
            tracing::info!(
                location_id = next_idx,
                "Job cleanup complete, returning to route planning"
            );

            // Loop back → re-plan with DP for remaining destinations.
        }
        tracing::info!("Printing loop ended, returning to idle state");
    }
}
