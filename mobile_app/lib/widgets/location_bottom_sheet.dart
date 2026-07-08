import 'package:flutter/material.dart';
import '../models/location.dart';
import 'location_map_widget.dart';

class LocationBottomSheet extends StatefulWidget {
  final List<Location> locations;

  const LocationBottomSheet({super.key, required this.locations});

  @override
  State<LocationBottomSheet> createState() => _LocationBottomSheetState();
}

class _LocationBottomSheetState extends State<LocationBottomSheet> {
  int? _selectedLocationId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.locations.isNotEmpty) {
      _selectedLocationId = widget.locations.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // showModalBottomSheet already wraps content in a Material widget.
    // We avoid adding our own outer Material to prevent nesting conflicts.
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 20),
          child: Row(
            children: [
              Text(
                '选择投递位置',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: theme.onSurface,
                ),
              ),
            ],
          ),
        ),

        // Map image
        LocationMapWidget(
          locations: widget.locations,
          selectedLocationId: _selectedLocationId,
        ),

        // Location options — each item has its own Material for ink effects.
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: widget.locations.map((loc) {
                final isSelected = _selectedLocationId == loc.id;
                return Material(
                  color: isSelected
                      ? theme.primary.withValues(alpha: 0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _selectedLocationId = loc.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Radio<int>(
                            value: loc.id,
                            groupValue: _selectedLocationId,
                            onChanged: (v) =>
                                setState(() => _selectedLocationId = v),
                            activeColor: theme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  loc.name,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    fontSize: 15,
                                  ),
                                ),
                                Text(
                                  loc.description.isNotEmpty
                                      ? loc.description
                                      : '(${loc.location.x.toStringAsFixed(1)}, ${loc.location.y.toStringAsFixed(1)})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.onSurface.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),

        // Submit button
        Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: bottomPadding + 12,
          ),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _selectedLocationId != null && !_submitting
                  ? _submit
                  : null,
              icon: _submitting
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.send_rounded, size: 18),
              label: const Text(
                '提交',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            ),
          ),
        ),
      ],
    );
  }

  void _submit() {
    if (_selectedLocationId == null) return;
    setState(() => _submitting = true);
    Navigator.of(context).pop(_selectedLocationId);
  }
}

/// Shows the location selection bottom sheet and returns the selected location ID.
Future<int?> showLocationBottomSheet({
  required BuildContext context,
  required List<Location> locations,
}) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => LocationBottomSheet(locations: locations),
  );
}
