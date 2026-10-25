import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class TripPoint {
  const TripPoint({
    required this.timestampMs,
    required this.latitude,
    required this.longitude,
    required this.speedMps,
    required this.accuracyM,
    this.altitudeM,
    this.bearingDeg,
  });

  final int timestampMs;
  final double latitude;
  final double longitude;
  final double speedMps;
  final double accuracyM;
  final double? altitudeM;
  final double? bearingDeg;

  Map<String, Object?> toMap(int tripId) => {
        'trip_id': tripId,
        'timestamp_ms': timestampMs,
        'latitude': latitude,
        'longitude': longitude,
        'speed_mps': speedMps,
        'accuracy_m': accuracyM,
        'altitude_m': altitudeM,
        'bearing_deg': bearingDeg,
      };
}

class TripStore {
  TripStore._();
  static final TripStore instance = TripStore._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final root = await getDatabasesPath();
    _database = await openDatabase(
      p.join(root, 'alangmotor_speed_recorder.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at_ms INTEGER NOT NULL,
            ended_at_ms INTEGER,
            vehicle_type TEXT NOT NULL,
            max_speed_mps REAL NOT NULL DEFAULT 0,
            distance_m REAL NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE trip_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            speed_mps REAL NOT NULL,
            accuracy_m REAL NOT NULL,
            altitude_m REAL,
            bearing_deg REAL,
            FOREIGN KEY(trip_id) REFERENCES trips(id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_trip_points_trip_time ON trip_points(trip_id, timestamp_ms)',
        );
      },
    );
    return _database!;
  }

  Future<int> startTrip(String vehicleType, int startedAtMs) async {
    final db = await database;
    return db.insert('trips', {
      'started_at_ms': startedAtMs,
      'vehicle_type': vehicleType,
    });
  }

  Future<void> addPoint(int tripId, TripPoint point, {required double maxSpeedMps, required double distanceM}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('trip_points', point.toMap(tripId));
      await txn.update(
        'trips',
        {'max_speed_mps': maxSpeedMps, 'distance_m': distanceM},
        where: 'id = ?',
        whereArgs: [tripId],
      );
    });
  }

  Future<void> finishTrip(int tripId, int endedAtMs) async {
    final db = await database;
    await db.update('trips', {'ended_at_ms': endedAtMs}, where: 'id = ?', whereArgs: [tripId]);
  }

  Future<List<Map<String, Object?>>> listTrips() async {
    final db = await database;
    return db.query('trips', orderBy: 'started_at_ms DESC', limit: 100);
  }

  Future<List<Map<String, Object?>>> getPoints(int tripId) async {
    final db = await database;
    return db.query('trip_points', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'timestamp_ms');
  }
}
