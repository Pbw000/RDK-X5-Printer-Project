import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/job.dart';
import '../models/location.dart';
import '../services/api_service.dart';

/// Renders the occupancy-grid map with location markers and an
/// optional real-time printer position indicator.
///
/// The rendered [ui.Image] is cached globally (static) so it is generated
/// only once per app lifetime and reused across bottom-sheet opens.
class LocationMapWidget extends StatefulWidget {
  final List<Location> locations;
  final int? selectedLocationId;

  /// When non-null, a printer marker is drawn at this world position.
  final PositionUpdate? printerPosition;

  const LocationMapWidget({
    super.key,
    required this.locations,
    this.selectedLocationId,
    this.printerPosition,
  });

  @override
  State<LocationMapWidget> createState() => _LocationMapWidgetState();
}

/// Interpolates between two [PositionUpdate] values component-wise,
/// since PositionUpdate does not define arithmetic operators.
class _PositionTween extends Tween<PositionUpdate> {
  _PositionTween({super.begin, super.end});

  @override
  PositionUpdate lerp(double t) => PositionUpdate(
    x: begin!.x + (end!.x - begin!.x) * t,
    y: begin!.y + (end!.y - begin!.y) * t,
    theta: begin!.theta + (end!.theta - begin!.theta) * t,
  );
}

class _LocationMapWidgetState extends State<LocationMapWidget>
    with SingleTickerProviderStateMixin {
  // ── Global static cache ──────────────────────────────────────────
  static ui.Image? _cachedImage;
  static MapUpdate? _cachedMapData;
  static bool _loading = false;
  static bool _fetched = false;

  // ── Printer position animation ──────────────────────────────────
  late final AnimationController _printerAnimController;
  Animation<PositionUpdate>? _printerAnim;
  PositionUpdate? _prevPosition;

  @override
  void initState() {
    super.initState();
    if (!_fetched && !_loading) _fetchMap();

    _printerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void didUpdateWidget(covariant LocationMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newPos = widget.printerPosition;
    if (newPos != null && newPos != oldWidget.printerPosition) {
      final from = _prevPosition ?? newPos;
      _printerAnim = _PositionTween(begin: from, end: newPos).animate(
        CurvedAnimation(parent: _printerAnimController, curve: Curves.easeOut),
      );
      _prevPosition = newPos;
      _printerAnimController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _printerAnimController.dispose();
    super.dispose();
  }

  Future<void> _fetchMap() async {
    _loading = true;
    try {
      final map = await ApiService.instance.getMap();
      _cachedMapData = map;
      _cachedImage = await _generateImage(map);
    } catch (_) {
      // leave cache null
    } finally {
      _loading = false;
      _fetched = true;
      if (mounted) setState(() {});
    }
  }

  // ── Image generation (runs once) ─────────────────────────────────
  static Future<ui.Image?> _generateImage(MapUpdate? map) async {
    if (map == null || map.data.isEmpty) return null;
    if (map.width == 0 || map.height == 0) return null;

    final bytes = base64Decode(map.data);
    final width = map.width;
    final height = map.height;
    final pixels = Uint8List(width * height * 4);

    for (int py = 0; py < height; py++) {
      // Occupancy grid is stored bottom-to-top; flip for image top-to-bottom.
      final gridRow = height - 1 - py;
      for (int px = 0; px < width; px++) {
        final idx = gridRow * width + px;
        if (idx >= bytes.length) continue;
        final v = bytes[idx].toSigned(8); // reinterpret u8 → i8
        int r, g, b;
        if (v == -1) {
          r = 200;
          g = 200;
          b = 200; // unknown – light gray
        } else if (v == 0) {
          r = 255;
          g = 255;
          b = 255; // free – white
        } else {
          final t = v / 100.0;
          final c = (255 * (1.0 - t)).round().clamp(0, 255);
          r = c;
          g = c;
          b = c; // occupied – darker = more probable
        }
        final offset = (py * width + px) * 4;
        pixels[offset] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = 0xFF;
      }
    }

    final descriptor = ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(pixels),
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  // ── Coordinate conversion ────────────────────────────────────────
  static Offset worldToPixel(
    double worldX,
    double worldY,
    MapUpdate map,
    ui.Image image,
  ) {
    final dx = (worldX - map.originX) / map.resolution;
    final dy = (worldY - map.originY) / map.resolution;
    // Flip Y: world Y-up → image Y-down
    return Offset(
      dx.clamp(0.0, image.width.toDouble()),
      (image.height - dy).clamp(0.0, image.height.toDouble()),
    );
  }

  // ── Build ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;

    // Still loading
    if (_loading || !_fetched) {
      return Container(
        height: 220,
        margin: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: theme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(child: CircularProgressIndicator(color: theme.primary)),
      );
    }

    final image = _cachedImage;
    final mapData = _cachedMapData;

    if (image == null || mapData == null || mapData.data.isEmpty) {
      return Container(
        height: 220,
        margin: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: theme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 32,
                color: theme.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 8),
              Text(
                '地图加载失败',
                style: TextStyle(color: theme.onSurface.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ),
      );
    }

    // Determine which printer position to use (animated or static).
    final printerPos =
        (_printerAnimController.isAnimating && _printerAnim != null)
        ? _printerAnim!.value
        : widget.printerPosition;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      padding: const EdgeInsets.all(4),

      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: image.width.toDouble(),
            height: image.height.toDouble(),
            child: CustomPaint(
              painter: _MapPainter(
                image: image,
                mapData: mapData,
                locations: widget.locations,
                selectedId: widget.selectedLocationId,
                theme: theme,
                printerPosition: printerPos,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Custom Painter ──────────────────────────────────────────────────

class _MapPainter extends CustomPainter {
  final ui.Image image;
  final MapUpdate mapData;
  final List<Location> locations;
  final int? selectedId;
  final ColorScheme theme;
  final PositionUpdate? printerPosition;

  _MapPainter({
    required this.image,
    required this.mapData,
    required this.locations,
    required this.selectedId,
    required this.theme,
    this.printerPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    canvas.drawImage(image, Offset.zero, paint);

    final markerRadius = math.max(size.shortestSide * 0.018, 12.0);
    final strokeWidth = math.max(markerRadius * 0.25, 2.0);

    // ── Location markers ────────────────────────────────────────
    for (final loc in locations) {
      final pos = _LocationMapWidgetState.worldToPixel(
        loc.location.x,
        loc.location.y,
        mapData,
        image,
      );
      final isSelected = loc.id == selectedId;

      canvas.drawCircle(
        pos,
        markerRadius,
        Paint()
          ..color = isSelected ? theme.primary : theme.secondary
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pos,
        markerRadius,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );

      final tp = _buildLabel(loc.name, isSelected);
      final labelX = pos.dx - tp.width / 2;
      final labelY = pos.dy - markerRadius - tp.height - 4;
      tp.paint(canvas, Offset(labelX, labelY));
    }

    // ── Printer marker ──────────────────────────────────────────
    if (printerPosition != null) {
      final pPos = _LocationMapWidgetState.worldToPixel(
        printerPosition!.x,
        printerPosition!.y,
        mapData,
        image,
      );
      final printerR = math.max(size.shortestSide * 0.022, 15.0);

      // Outer glow
      canvas.drawCircle(
        pPos,
        printerR + 5,
        Paint()
          ..color = const Color(0xFF34C759).withValues(alpha: 0.2)
          ..style = PaintingStyle.fill,
      );

      // Main body
      canvas.drawCircle(
        pPos,
        printerR,
        Paint()
          ..color = const Color(0xFF34C759)
          ..style = PaintingStyle.fill,
      );

      // White border
      canvas.drawCircle(
        pPos,
        printerR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(printerR * 0.2, 2.5),
      );

      // Direction arrow
      canvas.save();
      canvas.translate(pPos.dx, pPos.dy);
      // In screen coords: negate theta (world Y-up → screen Y-down).
      canvas.rotate(-printerPosition!.theta);
      final arrowPath = Path()
        ..moveTo(printerR * 0.8, 0)
        ..lineTo(-printerR * 0.4, -printerR * 0.5)
        ..lineTo(-printerR * 0.15, 0)
        ..lineTo(-printerR * 0.4, printerR * 0.5)
        ..close();
      canvas.drawPath(
        arrowPath,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );
      canvas.restore();

      // Label
      final tp = TextPainter(
        text: TextSpan(
          text: '打印机',
          style: TextStyle(
            color: const Color(0xFF34C759),
            fontSize: math.max(image.width * 0.022, 11.0),
            fontWeight: FontWeight.bold,
            shadows: const [
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(pPos.dx - tp.width / 2, pPos.dy - printerR - tp.height - 4),
      );
    }
  }

  TextPainter _buildLabel(String text, bool isSelected) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: isSelected ? theme.primary : theme.onSurface,
          fontSize: math.max(image.width * 0.022, 11.0),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          shadows: const [
            Shadow(color: Colors.white, blurRadius: 3),
            Shadow(color: Colors.white, blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.selectedId != selectedId ||
      old.locations != locations ||
      old.printerPosition != printerPosition;
}
