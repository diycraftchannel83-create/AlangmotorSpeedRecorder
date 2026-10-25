import 'package:flutter_test/flutter_test.dart';
import 'package:alangmotor_speed_recorder/trip_store.dart';

void main() {
  test('TripPoint stores timestamp, coordinates and GPS metadata', () {
    const point = TripPoint(
      timestampMs: 1234,
      latitude: -7.123,
      longitude: 108.456,
      speedMps: 12.5,
      accuracyM: 4.0,
      altitudeM: 300,
      bearingDeg: 90,
    );
    final map = point.toMap(9);
    expect(map['trip_id'], 9);
    expect(map['timestamp_ms'], 1234);
    expect(map['speed_mps'], 12.5);
    expect(map['accuracy_m'], 4.0);
  });
}
