plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.playtorrio.playtorrio_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.playtorrio.playtorrio_tv"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "device"
    productFlavors {
        create("original") {
            dimension = "device"
            // Default startup: full TorrServer + precache (see --dart-define LOW_RAM)
        }
        create("lowram") {
            dimension = "device"
            versionNameSuffix = "-lowram"
            // Build with: --dart-define=LOW_RAM=true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        resources {
            pickFirsts.add("lib/**/libc++_shared.so")
        }
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation("org.videolan.android:libvlc-all:3.6.5")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
}

flutter {
    source = "../.."
}
