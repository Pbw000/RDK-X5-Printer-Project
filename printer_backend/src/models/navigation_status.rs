//! Navigation status model.

use serde::Serialize;

/// Route segment: next destination and time to reach it.
#[derive(Debug, Clone, Serialize, Default)]
pub struct RouteSegment {
    /// Destination index for this segment.
    pub location_id: usize,
    /// Estimated travel time in seconds to reach this destination from the previous stop.
    pub estimated_time_secs: f64,
}

/// Navigation status exposed by the `/api/navigation/status` endpoint.
///
/// Refreshed by the background printing task each time a route is planned.
#[derive(Debug, Clone, Serialize, Default)]
pub struct NavigationStatus {
    /// The currently planned route segments, in visit order.
    pub route: Vec<RouteSegment>,
}

impl NavigationStatus {
    /// Build an empty / no-route status.
    pub fn empty() -> Self {
        Self {
            route: Vec::new(),
        }
    }

    /// Update the navigation status from a planned route using cached distances.
    pub fn update(&mut self, current_route: &[usize], distances: &[f64]) {
        self.route.clear();
        self.route.extend(
            current_route
                .iter()
                .copied()
                .zip(distances.iter())
                .map(|(location_id, distance)| RouteSegment {
                    location_id,
                    estimated_time_secs: *distance,
                }),
        );
    }
}
