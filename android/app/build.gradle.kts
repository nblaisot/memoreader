import java.util.Properties

// Load the keystore properties from key.properties
val keystorePropertiesFile = file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(keystorePropertiesFile.inputStream())
    }
}

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

    // Create a signing configuration for release using key.properties values
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // Use the release signing config instead of the debug one
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
