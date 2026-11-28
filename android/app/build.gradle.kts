plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
   
}

android {
    namespace = "com.example.trust_punch"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (shift-end reminders).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.trust_punch"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // tflite_flutter's native runtime requires 26; Flutter's default is lower.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Two apps from one codebase, installable side by side:
    //   demo      — the offline demo, unchanged (same id, name and data);
    //   connected — its own id and data; the only one that talks to the
    //               local server (run with -t lib/main_connected.dart).
    flavorDimensions += "edition"
    productFlavors {
        create("demo") {
            dimension = "edition"
            resValue("string", "app_name", "Trust Punch")
        }
        create("connected") {
            dimension = "edition"
            applicationIdSuffix = ".connected"
            resValue("string", "app_name", "TrustPunch Connected")
        }
    }

    buildFeatures {
        resValues = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Java 8+ APIs on older Android, for flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
