use crate::models::{
    Priority,
    location::PrintDests,
    navigation_status::NavigationStatus,
};
use crate::ros_nav::{MAX_NODES, PATH_CACHE};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SchedulerErr {
    #[error("empty target location")]
    EmptyTargetLocation,
    #[error("unexpected no solution found")]
    UnExpectedNoSolutionFound,
}

/// Upper bound for the bitmask DP solver.
/// Stack cost ≈ 3 × (1 << DP_MAX) × DP_MAX × 8 bytes.
/// DP_MAX = 12 → ~1.2 MB, safe for a typical 8 MB thread stack.
const DP_MAX: usize = 12;

/// Priority weight — higher = more urgent.
fn priority_weight(p: &Priority) -> usize {
    match p {
        Priority::Critical => 8,
        Priority::High => 4,
        Priority::Medium => 2,
        Priority::Low => 1,
    }
}

/// Aggregated priority weight for a destination (takes the max among jobs).
fn dest_weight(dests: &PrintDests, idx: usize) -> usize {
    dests.destinations[idx]
        .pending_jobs
        .iter()
        .map(|j| priority_weight(&j.priority))
        .max()
        .unwrap_or(1)
}

pub struct Scheduler;

/// Result returned by the route solver, carrying both visit order and navigation status.
pub struct RoutePlan {
    pub route: Vec<usize>,
    pub navigation_status: NavigationStatus,
}

impl Scheduler {
    pub async fn solve_route(&self, dests: &PrintDests) -> Result<RoutePlan, SchedulerErr> {
        // Collect the subset of destinations that have pending work.
        let work: Vec<usize> = dests
            .destinations
            .iter()
            .enumerate()
            .filter(|(_, d)| !d.pending_jobs.is_empty())
            .map(|(i, _)| i)
            .collect();

        if work.is_empty() {
            return Err(SchedulerErr::EmptyTargetLocation);
        }

        let n = work.len();
        if n == 1 {
            let cache = PATH_CACHE.read().await;
            let mut status = NavigationStatus::empty();
            let times = vec![cache[MAX_NODES][work[0]]];
            status.update(&work, &times);
            return Ok(RoutePlan {
                route: work,
                navigation_status: status,
            });
        }

        // Cap at DP_MAX for stack allocation.
        let n = n.min(DP_MAX);

        // ---- Snapshot the path cache once ----
        let cache = PATH_CACHE.read().await;

        // ---- Bitmask DP (stack-allocated) ----
        //
        // dp_cost[mask * n + i]  = min priority-weighted cumulative cost
        // dp_time[mask * n + i]  = cumulative travel distance to reach i
        // dp_prev[mask * n + i]  = previous node in the path (for backtracking)
        //
        // The total stack footprint is ~3 × (1 << DP_MAX) × DP_MAX × 8 bytes
        // ≈ 1.2 MB for DP_MAX = 12.

        const TABLE_LEN: usize = (1 << DP_MAX) * DP_MAX;
        let mut dp_cost = [f64::INFINITY; TABLE_LEN];
        let mut dp_time = [f64::INFINITY; TABLE_LEN];
        let mut dp_prev = [usize::MAX; TABLE_LEN];

        let idx = |mask: usize, i: usize| mask * n + i;

        // Distances: robot → each work destination (from path cache).
        let mut d_start = [f64::INFINITY; DP_MAX];
        for i in 0..n {
            d_start[i] = cache[MAX_NODES][work[i]];
        }

        // Distances: work[i] → work[j].
        let mut d = [[f64::INFINITY; DP_MAX]; DP_MAX];
        for i in 0..n {
            for j in 0..n {
                d[i][j] = if i == j {
                    0.0
                } else {
                    cache[work[i]][work[j]]
                };
            }
        }

        // Done reading cache.
        drop(cache);

        // Base cases: robot → single destination.
        for i in 0..n {
            let m = 1usize << i;
            let w = dest_weight(dests, work[i]);
            dp_time[idx(m, i)] = d_start[i];
            dp_cost[idx(m, i)] = (w as f64) * d_start[i];
        }

        let full_mask = (1usize << n) - 1;

        // Transitions.
        for mask in 1usize..=full_mask {
            for i in 0..n {
                if mask & (1usize << i) == 0 {
                    continue;
                }
                let ci = dp_cost[idx(mask, i)];
                if !ci.is_finite() {
                    continue;
                }
                let ti = dp_time[idx(mask, i)];

                for j in 0..n {
                    if mask & (1usize << j) != 0 {
                        continue;
                    }
                    let new_mask = mask | (1usize << j);
                    let new_time = ti + d[i][j];
                    let w_j = dest_weight(dests, work[j]) as f64;
                    let new_cost = ci + w_j * new_time;

                    if new_cost < dp_cost[idx(new_mask, j)] {
                        dp_cost[idx(new_mask, j)] = new_cost;
                        dp_time[idx(new_mask, j)] = new_time;
                        dp_prev[idx(new_mask, j)] = i;
                    }
                }
            }
        }

        // Find best ending node.
        let (best_end, _) = (0..n)
            .map(|i| (i, dp_cost[idx(full_mask, i)]))
            .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
            .ok_or(SchedulerErr::UnExpectedNoSolutionFound)?;

        if !dp_cost[idx(full_mask, best_end)].is_finite() {
            return Err(SchedulerErr::UnExpectedNoSolutionFound);
        }

        // Reconstruct visit order.
        let mut order = Vec::with_capacity(n);
        let mut mask = full_mask;
        let mut cur = best_end;
        while cur != usize::MAX && mask != 0 {
            order.push(work[cur]);
            let prev = dp_prev[idx(mask, cur)];
            mask &= !(1usize << cur);
            cur = prev;
        }
        order.reverse();

        // Build navigation status while still holding the route data.
        let nav_status = {
            let cache = PATH_CACHE.read().await;
            let mut times = Vec::with_capacity(order.len());
            if let Some(&first) = order.first() {
                times.push(cache[MAX_NODES][first]);
            }
            for w in order.windows(2) {
                times.push(cache[w[0]][w[1]]);
            }
            let mut status = NavigationStatus::empty();
            status.update(&order, &times);
            status
        };

        let total_distance: f64 = nav_status.route.iter().map(|s| s.estimated_time_secs).sum();
        tracing::info!(
            route = ?order,
            stops = order.len(),
            total_distance = format_args!("{:.2}", total_distance),
            "Scheduler: optimal route solved"
        );

        Ok(RoutePlan {
            route: order,
            navigation_status: nav_status,
        })
    }

}

