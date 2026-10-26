import 'dart:async';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'trip_store.dart';

const neonGreen = Color(0xFF39FF14);

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
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  Timer? _batteryRefreshTimer;
  int? _batteryLevel;
  BatteryState? _batteryState;
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
  DateTime? _stoppedSince;
  bool _autoStartRequested = false; // retained for compatibility with status rendering
  bool _feet = false;
  double _segmentStartM = 0;
  final List<_SpeedSegment> _segments = [];

  @override
  void initState() {
    super.initState();
    _refreshBattery();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_autoStartRequested) {
        _autoStartRequested = true;
        _start();
      }
    });
    _batterySubscription = _battery.onBatteryStateChanged.listen((state) {
      if (mounted) setState(() => _batteryState = state);
      _refreshBattery();
    });
    _batteryRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshBattery());
  }

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (mounted) setState(() { _batteryLevel = level; _batteryState = state; });
    } catch (_) {
      if (mounted) setState(() => _batteryLevel = null);
    }
  }

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
      var bg = await Permission.locationAlways.status;
      if (bg.isDenied || bg.isRestricted) {
        bg = await Permission.locationAlways.request();
      }
      if (!bg.isGranted) {
        if (mounted) setState(() => _status = 'Izinkan lokasi: Always / Selalu di pengaturan aplikasi agar GPS berjalan di latar belakang');
        await openAppSettings();
        return false;
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
        _position = null;
        _status = 'Menunggu posisi GPS valid untuk mulai merekam';
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
    // Mulai merekam saat motor bergerak; GPS tetap dipantau ketika motor berhenti.
    if (_armed && !_recording && speed * 3.6 >= 5.0) {
      try {
        final id = await TripStore.instance.startTrip(_vehicle, p.timestamp.millisecondsSinceEpoch);
        if (!mounted || !_armed) {
          await TripStore.instance.finishTrip(id, DateTime.now().millisecondsSinceEpoch);
          return;
        }
        _tripId = id;
        _recording = true;
        _startedAt = p.timestamp;
        _stoppedSince = null;
      } catch (e) {
        if (mounted) setState(() => _status = 'Gagal memulai rekaman: $e');
        return;
      }
    }

    // Otomatis akhiri dan simpan perjalanan jika kecepatan di bawah 2 km/jam selama 10 detik.
    if (_recording) {
      if (speed * 3.6 < 2.0) {
        _stoppedSince ??= p.timestamp;
        if (p.timestamp.difference(_stoppedSince!).inSeconds >= 10) {
          final id = _tripId;
          if (id != null) await TripStore.instance.finishTrip(id, p.timestamp.millisecondsSinceEpoch);
          _tripId = null;
          _recording = false;
          _startedAt = null;
          _stoppedSince = null;
          _lastAccepted = p;
          if (mounted) setState(() => _status = 'Motor berhenti — rekaman otomatis disimpan');
          return;
        }
      } else {
        _stoppedSince = null;
      }
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
    _status = _recording
        ? (p.accuracy <= 10 ? 'GPS hijau — rekaman otomatis berjalan' : 'GPS terkunci — akurasi sedang')
        : (p.accuracy <= 10 ? 'GPS hijau — menunggu motor bergerak' : 'GPS terkunci — akurasi sedang');
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
        _status = id == null ? 'GPS dinonaktifkan' : 'Rekaman disimpan di perangkat';
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
    _batteryRefreshTimer?.cancel();
    _batterySubscription?.cancel();
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
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Container(width: 44, height: 40, decoration: BoxDecoration(border: Border.all(color: (_position != null && _position!.accuracy <= 50 && _position!.latitude.isFinite && _position!.longitude.isFinite) ? neonGreen : Colors.redAccent, width: 1.5), borderRadius: BorderRadius.circular(9)), child: Icon(Icons.gps_fixed, color: (_position != null && _position!.accuracy <= 50 && _position!.latitude.isFinite && _position!.longitude.isFinite) ? neonGreen : Colors.redAccent, size: 25)),
                    Expanded(child: Text(_recording ? 'TRIP RECORDING' : _armed ? 'GPS AKTIF — SIAGA OTOMATIS' : 'GPS SPEEDOMETER', textAlign: TextAlign.center, style: const TextStyle(color: neonGreen, fontWeight: FontWeight.w800, letterSpacing: 1.5))),
                    Container(width: 44, height: 40, decoration: BoxDecoration(border: Border.all(color: Colors.redAccent, width: 1.5), borderRadius: BorderRadius.circular(9)), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(_batteryState == BatteryState.charging || _batteryState == BatteryState.full ? Icons.battery_charging_full : (_batteryLevel != null && _batteryLevel! <= 15 ? Icons.battery_alert : Icons.battery_full), color: _batteryLevel == null ? Colors.grey : (_batteryLevel! <= 15 ? Colors.redAccent : neonGreen), size: 22), if (_batteryLevel != null) Text('$_batteryLevel%', style: TextStyle(color: _batteryLevel! <= 15 ? Colors.redAccent : neonGreen, fontSize: 10, fontWeight: FontWeight.bold))])),
                  ]),
                  SizedBox(
                    width: double.infinity,
                    height: 310,
                    child: Stack(alignment: Alignment.center, children: [
                      Positioned.fill(child: CustomPaint(painter: _AnalogSpeedometerPainter(speedKmh: _speedKmh))),
                      Positioned(
                        top: 76,
                        child: Column(children: [
                          Text((_feet ? _speedKmh * 0.621371 : _speedKmh).toStringAsFixed(0), style: const TextStyle(color: Colors.white, fontSize: 68, height: 1, fontWeight: FontWeight.w300)),
                          const SizedBox(height: 2),
                          Text('MAX ${(_feet ? _maxMps * 2.23694 : _maxMps * 3.6).toStringAsFixed(0)}', style: const TextStyle(color: Color(0xFFFF3B30), fontSize: 14, fontWeight: FontWeight.bold)),
                        ]),
                      ),
                      Positioned(top: 232, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF071007), border: Border.all(color: neonGreen, width: 1.2), borderRadius: BorderRadius.circular(8)), child: Text(_feet ? 'mph' : 'km/h', style: const TextStyle(color: neonGreen, fontSize: 17, fontWeight: FontWeight.bold)))),
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
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TripLogPage())), icon: const Icon(Icons.history), label: const Text('LOG HASIL REKAMAN SPEED'), style: OutlinedButton.styleFrom(foregroundColor: neonGreen, side: const BorderSide(color: neonGreen), minimumSize: const Size.fromHeight(50))),
            const SizedBox(height: 20),
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
  bool shouldRepaint(covariant _SpeedChartPainter oldDelegate) => oldDelegate.segments != segments || oldDelegate.segments.length != segments.length;
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

class TripLogPage extends StatefulWidget {
  const TripLogPage({super.key});
  @override
  State<TripLogPage> createState() => _TripLogPageState();
}
class _TripLogPageState extends State<TripLogPage> {
  late Future<List<Map<String, Object?>>> _trips;
  @override
  void initState() { super.initState(); _load(); }
  void _load() { _trips = TripStore.instance.listTrips(); }
  String _date(Object? value) {
    if (value is! int) return 'Waktu tidak tersedia';
    final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Log Rekaman Speed'), actions: [IconButton(onPressed: () => setState(_load), icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<Map<String, Object?>>>(future: _trips, builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: neonGreen));
      if (snapshot.hasError) return Center(child: Text('Gagal membaca log: ${snapshot.error}'));
      final trips = snapshot.data ?? [];
      if (trips.isEmpty) return const Center(child: Text('Belum ada hasil rekaman tersimpan.'));
      return ListView.builder(padding: const EdgeInsets.all(12), itemCount: trips.length, itemBuilder: (context, index) {
        final trip = trips[index]; final maxMps = (trip['max_speed_mps'] as num?)?.toDouble() ?? 0; final distance = (trip['distance_m'] as num?)?.toDouble() ?? 0;
        final end = trip['ended_at_ms'];
        return Card(child: ListTile(leading: const Icon(Icons.route, color: neonGreen, size: 30),
          title: Text('${trip['vehicle_type']} • ${(maxMps * 3.6).toStringAsFixed(1)} km/h'),
          subtitle: Text('${_date(trip['started_at_ms'])}\nJarak ${(distance / 1000).toStringAsFixed(2)} km • ${end == null ? 'Belum selesai' : 'Selesai ${_date(end)}'}'),
          isThreeLine: true, trailing: const Icon(Icons.chevron_right, color: neonGreen),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TripDetailPage(trip: trip)))));
      });
    }),
  );
}
class TripDetailPage extends StatelessWidget {
  const TripDetailPage({super.key, required this.trip});
  final Map<String, Object?> trip;
  String _time(Object? value) {
    if (value is! int) return '--:--:--';
    final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Detail Rekaman')),
    body: FutureBuilder<List<Map<String, Object?>>>(future: TripStore.instance.getPoints(trip['id'] as int), builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(color: neonGreen));
      if (snapshot.hasError) return Center(child: Text('Gagal membaca titik: ${snapshot.error}'));
      final points = snapshot.data ?? [];
      if (points.isEmpty) return const Center(child: Text('Rekaman ini belum memiliki titik GPS.'));
      return ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Text('TITIK GPS TERSIMPAN: ${points.length}', style: const TextStyle(color: neonGreen, fontWeight: FontWeight.bold)))),
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('GRAFIK KECEPATAN REKAMAN', style: TextStyle(color: neonGreen, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(height: 190, child: CustomPaint(size: Size.infinite, painter: _SpeedChartPainter(List<_SpeedSegment>.generate(points.length, (i) {
            final p = points[i];
            final speed = ((p['speed_mps'] as num?)?.toDouble() ?? 0) * 3.6;
            final ts = p['timestamp_ms'] as int? ?? 0;
            final firstTs = points.first['timestamp_ms'] as int? ?? ts;
            return _SpeedSegment(distanceM: (ts - firstTs) / 1000.0, speedKmh: speed, elapsedSeconds: ((ts - firstTs) / 1000).round());
          })))),
          const SizedBox(height: 8),
          const Text('Sumbu horizontal: waktu sejak rekaman dimulai • Sumbu vertikal: kecepatan (km/h)', style: TextStyle(fontSize: 11, color: Colors.white60)),
        ]))),
        ...points.map((p) {
          final speed = ((p['speed_mps'] as num?)?.toDouble() ?? 0) * 3.6; final accuracy = (p['accuracy_m'] as num?)?.toDouble() ?? 0;
          return Card(child: ListTile(leading: const Icon(Icons.speed, color: neonGreen), title: Text('${speed.toStringAsFixed(1)} km/h'),
            subtitle: Text('${_time(p['timestamp_ms'])} • Akurasi ±${accuracy.toStringAsFixed(1)} m\n${(p['latitude'] as num).toStringAsFixed(6)}, ${(p['longitude'] as num).toStringAsFixed(6)}'), isThreeLine: true));
        }),
      ]);
    }),
  );
}
