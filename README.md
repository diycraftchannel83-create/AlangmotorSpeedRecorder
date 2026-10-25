# Alangmotor Speed Recorder

Offline-first GPS speed logger for motorcycles and cars.

## MVP features
- Live GPS speed in km/h, current GPS horizontal accuracy, maximum speed, distance and elapsed recording time.
- Start/stop recording and local SQLite session/point storage.
- Android location foreground notification while recording, including when the screen is off.
- CSV export is planned; route maps are intentionally deferred until recording reliability is validated.

## Build
This repository is bootstrapped as a Flutter Android app. Pushes and pull requests run the Android debug APK workflow in GitHub Actions.

1. Install Flutter stable and Android SDK.
2. Run `flutter pub get`.
3. Run `flutter analyze` and `flutter test`.
4. Run `flutter build apk --debug`.

## GPS accuracy and limitations
Android GPS speed is an estimate, not a certified speedometer. Accuracy depends on the handset, antenna placement, sky visibility and environment. The UI shows horizontal position accuracy where supplied; this is not the same as speed accuracy. This MVP does not claim external-GNSS receiver support. External GNSS will be evaluated separately against the receiver's documented protocol and Android mock/location integration.

## Background operation
Recording uses geolocator's Android foreground-notification configuration and requests location permission. Android may still stop location updates because of force-stop, vendor battery restrictions, revoked permissions, or device shutdown. Test on target devices with the screen off before relying on it.

## Safety and privacy
Mount the phone securely and do not operate the app while driving. Location records are stored locally on the device. The app does not upload trips.
