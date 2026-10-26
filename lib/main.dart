import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'trip_store.dart';

void main() => runApp(const SpeedRecorderApp());

class SpeedRecorderApp extends StatelessWidget {
  const SpeedRecorderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Alangmotor Speed Recorder',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: const ColorScheme.dark(primary: Color(0xFF39FF14), secondary: Color(0xFF39FF14), surface: Color(0xFF101510)), scaffoldBackgroundColor: const Color(0xFF050805), appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF050805), foregroundColor: Color(0xFF39FF14)), cardTheme: const CardThemeData(color: Color(0xFF101510), elevation: 4), textTheme: ThemeData.dark().textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white), useMaterial3: true),
        home: const RecorderHome(),
      );
}

class RecorderHome extends StatefulWidget {
  const RecorderHome({super.key});

  @override
  State<RecorderHome> createState() => _RecorderHomeState();
}

class _RecorderHomeState extends State<RecorderHome> {
  StreamSubscription<Position>? _subscription;
  Position? _position;
  int? _tripId;
  String _vehicle = 'Motor';
  String _status = 'Siap merekam';
  bool _recording = false;
  double _maxMps = 0;
  double _sumMps = 0;
  int _sampleCount = 0;
  double _distanceM = 0;
  DateTime? _startedAt;
  Position? _lastAccepted;
  bool _armed = false;
  bool _feet = false;
  double _segmentStartM = 0;
  final List<_SpeedSegment> _segments = [];

  double get _speedKmh {
    final speed = _position?.speed ?? 0;
    return speed.isFinite && speed >= 0 ? speed * 3.6 : 0;
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Aktifkan GPS/lokasi perangkat terlebih dahulu');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Izin lokasi belum diberikan');
      return false;
    }
    // Android 10+ requires background-location permission for some background
    // access patterns. A foreground location service is started explicitly.
    if (permission != LocationPermission.always) {
      final bg = await Permission.locationAlways.status;
      if (bg.isDenied) {
        await Permission.locationAlways.request();
      }
    }
    return true;
  }

  Future<void> _start() async {
    if (_recording || _armed) return;
    if (!await _ensureLocationPermission()) return;
    try {
      final settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 500),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Alangmotor Speed Recorder aktif',
          notificationText: 'GPS sedang merekam perjalanan',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
      setState(() {
        _tripId = null;
        _recording = false;
        _armed = true;
        _startedAt = null;
        _status = 'Auto record aktif — mulai bergerak untuk merekam';
        _maxMps = 0;
        _sumMps = 0;
        _sampleCount = 0;
        _distanceM = 0;
        _lastAccepted = null;
        _segmentStartM = 0;
        _segments.clear();
      });
      _subscription = Geolocator.getPositionStream(locationSettings: settings).listen(
        _onPosition,
        onError: (Object error) {
          if (mounted) setState(() => _status = 'GPS error: $error');
        },
      );
    } catch (e) {
      if (mounted) setState(() => _status = 'Gagal memulai: $e');
    }
  }

  Future<void> _onPosition(Position p) async {
    if (!mounted || (!_armed && !_recording)) return;
    final ageMs = DateTime.now().millisecondsSinceEpoch - p.timestamp.millisecondsSinceEpoch;
    final speed = p.speed.isFinite && p.speed >= 0 ? p.speed : 0.0;
    // Retain raw accepted samples, but reject stale fixes and very poor
    // horizontal accuracy. Threshold is configurable in a future iteration.
    if (ageMs > 5000 || ageMs < -5000 || !p.accuracy.isFinite || p.accuracy > 50) {
      setState(() {
        _position = p;
        _status = 'GPS lemah/data lama — titik tidak disimpan';
      });
      return;
    }
    if (_armed && !_recording && speed * 3.6 >= 5.0) {
      final id = await TripStore.instance.startTrip(_vehicle, p.timestamp.millisecondsSinceEpoch);
      if (!mounted) return;
      setState(() {
        _tripId = id;
        _recording = true;
        _startedAt = DateTime.now();
        _status = 'Gerakan terdeteksi — auto recording';
      });
    }
    final previous = _lastAccepted;
    if (previous != null) {
      final seconds = p.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
      if (seconds > 0 && seconds < 10) {
        final segment = Geolocator.distanceBetween(
          previous.latitude, previous.longitude, p.latitude, p.longitude,
        );
        // Ignore implausible coordinate jumps rather than inflating distance.
        final impliedSpeed = segment / seconds;
        if (segment.isFinite && impliedSpeed <= 100) _distanceM += segment;
      }
    }
    _lastAccepted = p;
    _maxMps = math.max(_maxMps, speed);
    if (_recording && _distanceM - _segmentStartM >= 100) {
      _segments.add(_SpeedSegment(distanceM: _segmentStartM + 100, speedKmh: speed * 3.6, elapsedSeconds: _startedAt == null ? 0 : p.timestamp.difference(_startedAt!).inSeconds));
      _segmentStartM += 100;
    }
    _sumMps += speed;
    _sampleCount++;
    _position = p;
    _status = p.accuracy <= 10 ? 'GPS baik' : 'GPS terkunci — akurasi sedang';
    final tripId = _tripId;
    if (tripId != null && _recording) {
      try {
        await TripStore.instance.addPoint(
        tripId,
        TripPoint(
          timestampMs: p.timestamp.millisecondsSinceEpoch,
          latitude: p.latitude,
          longitude: p.longitude,
          speedMps: speed,
          accuracyM: p.accuracy,
          altitudeM: p.altitude,
          bearingDeg: p.heading,
        ),
        maxSpeedMps: _maxMps,
          distanceM: _distanceM,
        );
      } catch (e) {
        _status = 'Gagal menyimpan titik: $e';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final id = _tripId;
    if (id != null) {
      await TripStore.instance.finishTrip(id, DateTime.now().millisecondsSinceEpoch);
    }
    if (mounted) {
      setState(() {
        _recording = false;
        _armed = false;
        _tripId = null;
        _status = id == null ? 'Auto record dibatalkan' : 'Rekaman disimpan di perangkat';
      });
    }
  }

  String _duration() {
    final start = _startedAt;
    if (start == null) return '00:00';
    final seconds = DateTime.now().difference(start).inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _position;
    return Scaffold(
      appBar: AppBar(title: const Text('Alangmotor Speed Recorder', style: TextStyle(fontWeight: FontWeight.w700)),),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Motor', label: Text('Motor'), icon: Icon(Icons.two_wheeler)),
                ButtonSegment(value: 'Mobil', label: Text('Mobil'), icon: Icon(Icons.directions_car)),
              ],
              selected: {_vehicle},
              onSelectionChanged: _recording ? null : (v) => setState(() => _vehicle = v.first),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Expanded(child: Text('UNIT JARAK', style: TextStyle(fontWeight: FontWeight.bold))),
              SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('m / km')), ButtonSegment(value: true, label: Text('ft / mi'))], selected: {_feet}, onSelectionChanged: (v) => setState(() => _feet = v.first)),
            ]),
            Card(
              color: const Color(0xFF020602),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                child: Column(children: [
                  Text(_recording ? 'TRIP RECORDING' : _armed ? 'AUTO RECORD AKTIF' : 'GPS SPEEDOMETER',
                    style: const TextStyle(color: Color(0xFF00B8F0), fontWeight: FontWeight.w800, letterSpacing: 2)),
                  SizedBox(
                    width: double.infinity,
                    height: 310,
                    child: Stack(alignment: Alignment.center, children: [
                      Positioned.fill(child: CustomPaint(painter: _AnalogSpeedometerPainter(speedKmh: _speedKmh))),
                      Positioned(
                        top: 82,
                        child: Column(children: [
                          Text(_feet ? 'mph' : 'km/h', style: const TextStyle(color: Color(0xFF39FF14), fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text((_feet ? _speedKmh * 0.621371 : _speedKmh).toStringAsFixed(0),
                            style: const TextStyle(color: Colors.white, fontSize: 68, height: 1, fontWeight: FontWeight.w300)),
                          const SizedBox(height: 4),
                          Text('MAX ${(_feet ? _maxMps * 2.23694 : _maxMps * 3.6).toStringAsFixed(0)}',
                            style: const TextStyle(color: Color(0xFFFFA51F), fontSize: 14, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    ]),
                  ),
                  Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric('Maksimum', '${(_maxMps * 3.6).toStringAsFixed(1)} km/j')),
              const SizedBox(width: 8),
              Expanded(child: _metric('Rata-rata sampel', '${(_sampleCount == 0 ? 0 : _sumMps / _sampleCount * 3.6).toStringAsFixed(1)} km/j')),
              const SizedBox(width: 8),
              Expanded(child: _metric('Jarak', _feet ? '${(_distanceM * 3.28084).toStringAsFixed(0)} ft' : '${(_distanceM / 1000).toStringAsFixed(2)} km')),
            ]),
            const SizedBox(height: 8),
            _metric('Durasi rekaman', _duration()),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'KECEPATAN SETIAP 100 M',
                      style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 160,
                      child: CustomPaint(
                        painter: _SpeedChartPainter(_segments),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    if (_segments.isEmpty)
                      const Text(
                        'Grafik terisi setelah menempuh 100 meter.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ..._segments.reversed.take(5).map(
                      (s) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _feet
                                    ? '${(s.distanceM * 3.28084).toStringAsFixed(0)} ft'
                                    : '${s.distanceM.toStringAsFixed(0)} m',
                              ),
                            ),
                            Expanded(child: Text('${(_feet ? s.speedKmh * 0.621371 : s.speedKmh).toStringAsFixed(1)} ${_feet ? 'mph' : 'km/h'}')),
                            Text(_formatElapsed(s.elapsedSeconds)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _metric('Akurasi posisi GPS', p == null ? '—' : '±${p.accuracy.toStringAsFixed(1)} m'),
            const SizedBox(height: 8),
            _metric('Koordinat', p == null ? 'Belum tersedia' : '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: (_recording || _armed) ? _stop : _start,
              icon: Icon((_recording || _armed) ? Icons.stop : Icons.fiber_manual_record),
              label: Text(_recording ? 'STOP & SIMPAN' : _armed ? 'BATAL AUTO RECORD' : 'AUTO RECORD SAAT BERGERAK'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            ),
            const SizedBox(height: 12),
            const Text('Data disimpan secara lokal. Akurasi posisi bukan ukuran akurasi kecepatan. Jangan mengoperasikan HP saat kendaraan berjalan.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 5),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}


class _SpeedSegment {
  const _SpeedSegment({required this.distanceM, required this.speedKmh, required this.elapsedSeconds});
  final double distanceM;
  final double speedKmh;
  final int elapsedSeconds;
}

String _formatElapsed(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class _SpeedChartPainter extends CustomPainter {
  _SpeedChartPainter(this.segments);
  final List<_SpeedSegment> segments;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Colors.white12..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (segments.isEmpty) return;
    final maxSpeed = math.max(10.0, segments.map((s) => s.speedKmh).reduce(math.max) * 1.15);
    final path = Path();
    for (var i = 0; i < segments.length; i++) {
      final x = segments.length == 1 ? size.width / 2 : size.width * i / (segments.length - 1);
      final y = size.height - (segments[i].speedKmh / maxSpeed * (size.height - 12)) - 6;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = const Color(0xFFFF3B30));
    }
    canvas.drawPath(path, Paint()..color = const Color(0xFF39FF14)..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
  }
  @override
  bool shouldRepaint(covariant _SpeedChartPainter oldDelegate) => oldDelegate.segments.length != segments.length;
}


class _AnalogSpeedometerPainter extends CustomPainter {
  const _AnalogSpeedometerPainter({required this.speedKmh});
  final double speedKmh;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height * .57);
    final radius = side * .43;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = const Color(0xFF00B8F0).withValues(alpha: .16)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center, radius * .96, glow);
    canvas.drawCircle(center, radius, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..shader = const SweepGradient(
        colors: [Color(0xFF05212D), Color(0xFF00B8F0), Color(0xFFB9FFAE), Color(0xFF178A12), Color(0xFF05212D)],
      ).createShader(bounds);
    canvas.drawCircle(center, radius * .96, rim);

    const start = math.pi * .75;
    const sweep = math.pi * 1.5;
    for (var i = 0; i <= 60; i++) {
      final angle = start + sweep * i / 60;
      final major = i % 5 == 0;
      final innerR = radius * (major ? .72 : .79);
      final outerR = radius * .88;
      final paint = Paint()
        ..color = major ? Colors.white : const Color(0xFF00B8F0).withValues(alpha: .85)
        ..strokeWidth = major ? 2.2 : 1
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(center.dx + math.cos(angle) * innerR, center.dy + math.sin(angle) * innerR),
        Offset(center.dx + math.cos(angle) * outerR, center.dy + math.sin(angle) * outerR),
        paint,
      );
      if (major) {
        final label = (i ~/ 5 * 10).toString();
        final labelR = radius * .61;
        final pos = Offset(center.dx + math.cos(angle) * labelR, center.dy + math.sin(angle) * labelR);
        final tp = TextPainter(
          text: TextSpan(text: label, style: TextStyle(color: Colors.white.withValues(alpha: .85), fontSize: radius * .095, fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
      }
    }
    final needleAngle = start + sweep * (speedKmh.clamp(0, 120) / 120);
    final needlePaint = Paint()
      ..color = const Color(0xFFFFA51F)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, Offset(center.dx + math.cos(needleAngle) * radius * .69, center.dy + math.sin(needleAngle) * radius * .69), needlePaint);
    canvas.drawCircle(center, 8, Paint()..color = const Color(0xFFFFA51F));
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _AnalogSpeedometerPainter oldDelegate) => oldDelegate.speedKmh != speedKmh;
}
