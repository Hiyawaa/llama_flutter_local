plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android") // Use the ID, not the shorthand
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.llama_flutter_local"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    // Fix: aaptOptions must be inside the android block
    aaptOptions {
        noCompress.add("tflite")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.llama_flutter_local"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Fix: Use the new compilerOptions DSL instead of kotlinOptions
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/llama-cpp-dart.aar"))
}
