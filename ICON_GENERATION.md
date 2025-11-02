# App Icon Generation

Due to dependency conflicts between `epubx` (uses image ^3.0.8) and icon generation packages (require image ^4.0+), icons need to be generated manually.

## Option 1: Manual Icon Setup

### Android
Copy `memoreader.png` to:
- `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` (48x48)
- `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` (72x72)
- `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` (96x96)
- `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` (144x144)
- `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` (192x192)

### iOS
Replace the icon files in `ios/Runner/Assets.xcassets/AppIcon.appiconset/` with appropriately sized versions of `memoreader.png`.

## Option 2: Use Online Tools

1. Use an online icon generator like:
   - https://appicon.co/
   - https://icon.kitchen/
   - https://www.appicon.build/

2. Upload `memoreader.png` and generate icons for Android and iOS

3. Download and extract to the appropriate directories

## Option 3: Wait for Package Updates

Once `epubx` or icon generation packages are updated to be compatible, you can:
1. Add `flutter_launcher_icons` back to `pubspec.yaml`
2. Run `flutter pub run flutter_launcher_icons`

