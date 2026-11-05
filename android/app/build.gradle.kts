plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.puj_dispatch_system"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.puj_dispatch_system"
        minSdk = flutter.minSdkVersion  // <-- Updated to 23 for Firebase Phone Auth & Security
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 1. Define flavor dimension
    flavorDimensions += "default"

    // 2. Define the two separate app targets
    productFlavors {
        create("commuter") {
            dimension = "default"
            applicationIdSuffix = ".commuter"
            manifestPlaceholders["appName"] = "JeePeS Commuter"
        }
        create("staff") {
            dimension = "default"
            applicationIdSuffix = ".staff"
            manifestPlaceholders["appName"] = "JeePeS Operations"
        }
    }

    buildTypes {
        release {
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
