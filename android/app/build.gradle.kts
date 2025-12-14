plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.memoreader"
    // Use maxOf to ensure compileSdk is at least 35 for 16 KB page size support (Android 15+ requirement)
    // This respects Flutter's SDK management while ensuring compliance with Google Play requirements
    compileSdk = maxOf(flutter.compileSdkVersion, 35)
    // Ensure NDK r26+ for 16 KB page size support
    // Flutter will use the appropriate NDK version, but we can override if needed
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.memoreader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Use maxOf to ensure targetSdk is at least 35 for 16 KB page size support (Android 15+ requirement)
        // This respects Flutter's SDK management while ensuring compliance with Google Play requirements
        // Also ensures minSdk <= targetSdk constraint is always satisfied
        targetSdk = maxOf(flutter.targetSdkVersion, 35)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
