typedef LocationCoord = ({double x, double y});

class Location {
  final int id;
  final String name;
  final String description;
  final LocationCoord location;

  const Location({
    required this.id,
    required this.name,
    this.description = '',
    required this.location,
  });

  factory Location.fromJson(Map<String, dynamic> json, {int? id}) {
    final loc = json['location'] as Map<String, dynamic>?;
    return Location(
      id: id ?? (json['id'] as int? ?? 0),
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      location: (
        x: (loc?['x_cord'] as num?)?.toDouble() ?? 0.0,
        y: (loc?['y_cord'] as num?)?.toDouble() ?? 0.0,
      ),
    );
  }
}

/// Wraps the /api/locations response: { "destinations": [...] }
class PrintDests {
  final List<Location> destinations;
  const PrintDests(this.destinations);

  factory PrintDests.fromJson(Map<String, dynamic> json) {
    final list = json['destinations'] as List<dynamic>? ?? [];
    return PrintDests(
      list
          .asMap()
          .entries
          .map(
            (e) =>
                Location.fromJson(e.value as Map<String, dynamic>, id: e.key),
          )
          .toList(),
    );
  }
}
