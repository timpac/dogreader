import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The same compile-time switch selects both Dart policy and the Android package.
// Keep the ordinary build and its original application ID unchanged.
val experimentalBuild = (project.findProperty("dart-defines") as? String ?: "")
    .split(",").filter { it.isNotEmpty() }
    .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    .contains("DOGREADER_EXPERIMENTAL=true")
check(!experimentalBuild || project.findProperty("dogreaderTestBuild") != "true") {
    "Experimental and native-test installation modes must not be combined"
}

android {
    namespace = "com.example.audiobook_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.audiobook_app"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // CI debug builds install alongside the existing Dogreader app.
        // Production/local builds keep their original application ID.
        manifestPlaceholders["dogreaderAppIcon"] = "@mipmap/ic_launcher"
        if (experimentalBuild) {
            applicationIdSuffix = ".experimental"
            testApplicationId = "com.example.audiobook_app.experimental.runner"
            manifestPlaceholders["dogreaderAppLabel"] = "Dog Reader 2.0"
            manifestPlaceholders["dogreaderAppIcon"] = "@drawable/ic_launcher_experimental"
        } else if (project.findProperty("dogreaderTestBuild") == "true") {
            applicationIdSuffix = ".test"
            testApplicationId = "com.example.audiobook_app.test.runner"
            manifestPlaceholders["dogreaderAppLabel"] = "Dogreader Test"
        } else {
            manifestPlaceholders["dogreaderAppLabel"] = "Dogreader"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // CI uses the recovered Chromebook key to preserve Android update compatibility.
    // Local builds retain their normal Android debug signing behavior.
    signingConfigs {
        create("originalDogreader") {
            storeFile = file(System.getProperty("user.home") + "/.android/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        getByName("debug") {
            if (project.findProperty("dogreaderOriginalUpdate") == "true") {
                signingConfig = signingConfigs.getByName("originalDogreader")
            }
        }
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
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
