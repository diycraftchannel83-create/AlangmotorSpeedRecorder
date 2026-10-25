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
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)), useMaterial3: true),
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
    if (_recording) return;
    if (!await _ensureLocationPermission()) return;
    try {
      final id = await TripStore.instance.startTrip(_vehicle, DateTime.now().millisecondsSinceEpoch);
      const settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: Duration(milliseconds: 500),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Alangmotor Speed Recorder aktif',
          notificationText: 'GPS sedang merekam perjalanan',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
      setState(() {
        _tripId = id;
        _recording = true;
        _startedAt = DateTime.now();
        _status = 'Mencari data GPS...';
        _maxMps = 0;
        _sumMps = 0;
        _sampleCount = 0;
        _distanceM = 0;
        _lastAccepted = null;
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
    if (!mounted || !_recording || _tripId == null) return;
    final age = DateTime.now().difference(p.timestamp).abs();
    final speed = p.speed.isFinite && p.speed >= 0 ? p.speed : 0.0;
    // Retain raw accepted samples, but reject stale fixes and very poor
    // horizontal accuracy. Threshold is configurable in a future iteration.
    if (age > const Duration(seconds: 5) || !p.accuracy.isFinite || p.accuracy > 50) {
      setState(() {
        _position = p;
        _status = 'GPS lemah/data lama — titik tidak disimpan';
      });
      return;
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
    _sumMps += speed;
    _sampleCount++;
    _position = p;
    _status = p.accuracy <= 10 ? 'GPS baik' : 'GPS terkunci — akurasi sedang';
    final tripId = _tripId!;
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
        _tripId = null;
        _status = 'Rekaman disimpan di perangkat';
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
      appBar: AppBar(title: const Text('Alangmotor Speed Recorder')),
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
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                child: Column(children: [
                  Text(_recording ? 'KECEPATAN GPS' : 'SPEEDOMETER GPS', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_speedKmh.toStringAsFixed(1), style: Theme.of(context).textTheme.displayLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 68)),
                  const Text('km/jam'),
                  const SizedBox(height: 12),
                  Text(_status, textAlign: TextAlign.center),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric('Maksimum', '${(_maxMps * 3.6).toStringAsFixed(1)} km/j')),
              const SizedBox(width: 8),
              Expanded(child: _metric('Rata-rata sampel', '${(_sampleCount == 0 ? 0 : _sumMps / _sampleCount * 3.6).toStringAsFixed(1)} km/j')),
              const SizedBox(width: 8),
              Expanded(child: _metric('Jarak', '${(_distanceM / 1000).toStringAsFixed(2)} km')),
            ]),
            const SizedBox(height: 8),
            _metric('Durasi rekaman', _duration()),
            const SizedBox(height: 12),
            _metric('Akurasi posisi GPS', p == null ? '—' : '±${p.accuracy.toStringAsFixed(1)} m'),
            const SizedBox(height: 8),
            _metric('Koordinat', p == null ? 'Belum tersedia' : '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _recording ? _stop : _start,
              icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(_recording ? 'Selesai & Simpan' : 'Mulai Rekaman'),
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
