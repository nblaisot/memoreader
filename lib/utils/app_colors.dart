import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;

/// App color scheme based on brain icon (pink/magenta tones)
class AppColors {
  // Primary brain color - pink/magenta tone (typical brain icon color)
  // Can be adjusted to match the actual brain color in the image
  static const Color brainPink = Color(0xFFE91E63); // Material Pink
  static const Color brainPinkLight = Color(0xFFF8BBD0); // Light pink
  static const Color brainPinkDark = Color(0xFFC2185B); // Dark pink
  
  // Secondary colors for accents
  static const Color secondaryPurple = Color(0xFF9C27B0); // Purple accent
  static const Color secondaryPurpleLight = Color(0xFFE1BEE7); // Light purple
  
  // Neutral colors
  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFAFAFA);
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);
  
  /// Extract dominant color from an image
  /// This can be used to dynamically extract the brain color from the icon
  static Future<Color> extractDominantColor(String imagePath) async {
    try {
      final ByteData data = await rootBundle.load(imagePath);
      final Uint8List bytes = data.buffer.asUint8List();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;
      
      // Get pixel data once
      final ByteData? pixelData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      
      if (pixelData == null) {
        return brainPink;
      }
      
      // Sample pixels from the center region (where brain likely is)
      final int centerX = image.width ~/ 2;
      final int centerY = image.height ~/ 2;
      final int sampleSize = (image.width * 0.3).toInt().clamp(10, image.width ~/ 2);
      
      int r = 0, g = 0, b = 0, count = 0;
      
      for (int y = centerY - sampleSize ~/ 2; 
           y < centerY + sampleSize ~/ 2 && y < image.height; 
           y++) {
        for (int x = centerX - sampleSize ~/ 2; 
             x < centerX + sampleSize ~/ 2 && x < image.width; 
             x++) {
          if (x >= 0 && y >= 0 && x < image.width && y < image.height) {
            final offset = (y * image.width + x) * 4;
            r += pixelData.getUint8(offset);
            g += pixelData.getUint8(offset + 1);
            b += pixelData.getUint8(offset + 2);
            count++;
          }
        }
      }
      
      if (count > 0) {
        return Color.fromRGBO(
          r ~/ count,
          g ~/ count,
          b ~/ count,
          1.0,
        );
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
    }
    
    // Fallback to default brain color
    return brainPink;
  }
  
  /// Get the app color scheme
  static ColorScheme get colorScheme {
    return ColorScheme.fromSeed(
      seedColor: brainPink,
      brightness: Brightness.light,
      primary: brainPink,
      onPrimary: Colors.white,
      secondary: secondaryPurple,
      onSecondary: Colors.white,
      tertiary: brainPinkLight,
      surface: surface,
      onSurface: textPrimary,
      error: Colors.red,
      onError: Colors.white,
    );
  }
  
  /// Get color scheme from a seed color (for dynamic color extraction)
  static ColorScheme getColorSchemeFromColor(Color seedColor) {
    return ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
      primary: seedColor,
      onPrimary: Colors.white,
      secondary: secondaryPurple,
      onSecondary: Colors.white,
      tertiary: brainPinkLight,
      surface: surface,
      onSurface: textPrimary,
      error: Colors.red,
      onError: Colors.white,
    );
  }
}

