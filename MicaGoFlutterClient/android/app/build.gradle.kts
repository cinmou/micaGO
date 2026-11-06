import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use(keystoreProperties::load)
}

val releaseSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val releaseSigningConfigured = releaseSigningKeys.all {
    !keystoreProperties.getProperty(it).isNullOrBlank()
}
val releaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseBuildRequested && !releaseSigningConfigured) {
    throw GradleException(
        "Release signing is not configured. Add android/key.properties; " +
            "debug signing is intentionally not accepted for release builds.",
    )
}

android {
    namespace = "com.micago.message.mica_go"
    // C19: file_picker (and its flutter_plugin_android_lifecycle transitive dep)
    // require compileSdk 36. compileSdk only affects which APIs are available at
    // compile time — it does not change minSdk/targetSdk (runtime behavior or
    // device support), so this is the safe, recommended bump.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // C22: flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.micago.message.mica_go"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Current Flutter supports Android 7.0 (API 24) and newer.
        // Keep the lowest supported floor; compileSdk does not raise it.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Opt-in side-by-side debug install next to a release build signed
            // with another key: flutter build apk --debug
            //   --android-project-arg=micagoAppIdSuffix=.dev
            (project.findProperty("micagoAppIdSuffix") as String?)
                ?.takeIf { it.isNotBlank() }
                ?.let { applicationIdSuffix = it }
        }
        release {
            signingConfig = signingConfigs.findByName("release")
            // C62: keep ML Kit barcode classes — R8 full mode stripped them and
            // the QR scanner NPE'd in release builds only (see proguard-rules.pro).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

// The UnifiedPush connector depends on the JVM `tink` artifact while
// flutter_secure_storage uses `tink-android`, which already contains the same
// classes. Keep only the Android build.
configurations.configureEach {
    exclude(group = "com.google.crypto.tink", module = "tink")
}

dependencies {
    // C22: required by flutter_local_notifications for Java 8+ API desugaring.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // UnifiedPush fallback for users without another distributor: registers
    // with Google Play services' native WebPush endpoint using the server's
    // VAPID key. No Google SDK blobs and no Firebase project.
    implementation("org.unifiedpush.android:embedded-fcm-distributor:3.1.0")
}
