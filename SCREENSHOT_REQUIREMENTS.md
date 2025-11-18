# Screenshot Requirements Quick Reference

## 📱 Google Play Store

### Phone Screenshots
- **Required**: 2-8 screenshots
- **Format**: JPEG or 24-bit PNG (no alpha)
- **Recommended Size**: 1080 x 1920 pixels (portrait)
- **Alternative**: 1920 x 1080 pixels (landscape)
- **Constraints**: 
  - Min: 320px (shortest side)
  - Max: 3840px (longest side)
  - Max dimension ≤ 2x min dimension

### Tablet Screenshots (Optional)
- **Required**: 2-8 screenshots (if supporting tablets)
- **Format**: Same as phone
- **Recommended Size**: 1200 x 1920 pixels (portrait) or 1920 x 1200 pixels (landscape)

### Other Assets
- **App Icon**: 512 x 512 pixels (PNG with alpha, but no transparency in final)
- **Feature Graphic**: 1024 x 500 pixels (JPEG or PNG)

---

## 🍎 Apple App Store

### iPhone Screenshots
- **Required**: 1-10 screenshots
- **Format**: JPEG or PNG
- **Minimum Required Size**: iPhone 6.7" (1290 x 2796 pixels)
  - This will auto-scale for all iPhone sizes
- **Other Sizes** (if you want device-specific):
  - iPhone 6.5": 1242 x 2688 pixels
  - iPhone 5.5": 1242 x 2208 pixels
  - iPhone 4.7": 750 x 1334 pixels

### iPad Screenshots (If Supporting iPad)
- **Required**: 1-10 screenshots
- **Format**: JPEG or PNG
- **Recommended Sizes**:
  - iPad Pro 12.9": 2048 x 2732 pixels
  - iPad Pro 11": 1668 x 2388 pixels
  - iPad 10.2": 1620 x 2160 pixels

### Other Assets
- **App Icon**: 1024 x 1024 pixels (PNG or JPEG, no transparency)

---

## 📸 Recommended Screenshots to Capture

1. **Library/Home Screen** - Show your book collection
2. **Reader View** - Show the reading experience with text
3. **Settings Screen** - Show customization options
4. **Import Flow** - Show how to add books
5. **Summary/Chapter View** - Show AI summary feature (if applicable)
6. **Navigation** - Show menu or navigation features

**Tip**: Take screenshots on actual devices or use simulators/emulators at the correct resolutions.

---

## 🛠️ How to Take Screenshots

### Android (Physical Device)
1. Open your app
2. Navigate to the screen you want
3. Press Power + Volume Down simultaneously
4. Screenshot saved to Photos/Gallery

### Android (Emulator)
1. Open Android Studio
2. Run your app in emulator
3. Click camera icon in emulator toolbar
4. Or use: `adb shell screencap -p /sdcard/screenshot.png`

### iOS (Physical Device)
1. Open your app
2. Navigate to the screen you want
3. Press Power + Volume Up (or Home + Power on older devices)
4. Screenshot saved to Photos

### iOS (Simulator)
1. Open Xcode Simulator
2. Run your app
3. File → New Screen Recording (or Cmd+S for screenshot)
4. Or use: Cmd+S to save screenshot

### Flutter Screenshot Package (Programmatic)
You can also use the `screenshot` package to programmatically capture screenshots:
```dart
// Add to pubspec.yaml
dependencies:
  screenshot: ^2.1.0

// Use in code
final controller = ScreenshotController();
await controller.capture().then((image) {
  // Save image
});
```

---

## ✂️ Image Editing Tips

1. **Remove Status Bar** (Optional but recommended):
   - Use image editor to crop out status bar
   - Makes screenshots look cleaner

2. **Add Device Frames** (Optional):
   - Tools like [AppMockUp](https://app-mockup.com) or [Screenshot Framer](https://screenshot.rocks)
   - Makes screenshots look more professional

3. **Optimize File Size**:
   - Compress images while maintaining quality
   - Use tools like TinyPNG or ImageOptim

4. **Consistency**:
   - Use same device frame style for all screenshots
   - Keep similar content positioning

---

## 📋 Checklist

### Google Play
- [ ] 2-8 phone screenshots (1080x1920 recommended)
- [ ] 2-8 tablet screenshots (if applicable)
- [ ] App icon (512x512)
- [ ] Feature graphic (1024x500)

### Apple App Store
- [ ] 1-10 iPhone screenshots (1290x2796 minimum)
- [ ] 1-10 iPad screenshots (if supporting iPad)
- [ ] App icon (1024x1024)

---

## 🎨 Screenshot Tools & Resources

- **AppMockUp**: https://app-mockup.com - Add device frames
- **Screenshot.rocks**: https://screenshot.rocks - Generate screenshots with frames
- **Figma**: Design mockups and export screenshots
- **Canva**: Create feature graphics and promotional images
- **TinyPNG**: Compress images without quality loss

---

**Remember**: Screenshots are often the first thing users see. Make them count! Show your app's best features clearly and attractively.

