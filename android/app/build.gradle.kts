import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration — declared here but NOT auto-applied;
    // see the conditional `apply(plugin = ...)` block below. A fresh clone
    // with no google-services.json (gitignored, no committed placeholder)
    // used to hard-fail the build here. Firebase telemetry is now optional:
    // no file -> these plugins simply never get applied, app builds and runs
    // fine without Crashlytics/Analytics/Performance.
    id("com.google.gms.google-services") apply false
    id("com.google.firebase.firebase-perf") apply false
    id("com.google.firebase.crashlytics") apply false
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Only wire up Firebase when a real, non-empty google-services.json is
// present (see note above) — keeps a from-scratch clone buildable with zero
// Firebase credentials, real or placeholder. `.exists()` alone isn't enough:
// CI writes this file unconditionally from a secret
// (`base64 -d > google-services.json`), so a fork or run with that secret
// unset/blank still produces a 0-byte file that would pass `.exists()` and
// then fail the google-services plugin trying to parse it.
val hasRealGoogleServicesJson = file("google-services.json").let { it.exists() && it.length() > 0 }
if (hasRealGoogleServicesJson) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.firebase-perf")
    apply(plugin = "com.google.firebase.crashlytics")
}

// Release signing. Locally this reads android/key.properties; in CI the same values
// arrive as env vars (the workflow decodes the keystore from a secret). If neither is
// present we fall back to debug signing so a plain `flutter run` still works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
fun signingValue(propKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propKey) ?: System.getenv(envKey)
val hasReleaseSigning =
    signingValue("storeFile", "ANDROID_KEYSTORE_PATH") != null

android {
    namespace = "wtf.openstrap.openstrap_edge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by ota_update 7.x (desugars java.time/java.nio APIs on older API levels).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "wtf.openstrap.openstrap_edge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(26, flutter.minSdkVersion) // Health Connect requires API 26+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The launcher label comes from here so a debug build can say "Dev".
        manifestPlaceholders["appLabel"] = "Edge"

        // Retain FULL native debug symbols in the release bundle so Play Console
        // AND Crashlytics can symbolicate native/ANR frames. Without this, ANRs
        // sampled in native code (e.g. libm.so __kernel_rem_pio2 / sin / cos, and
        // the Dart AOT frames in libapp.so) show up as raw addresses / blank
        // frames with "root cause unknown" — which is exactly why the v42 staging
        // ANRs on 0.9.13 were unsymbolicated and hard to triage.
        ndk {
            debugSymbolLevel = "FULL"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(signingValue("storeFile", "ANDROID_KEYSTORE_PATH")!!)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // A debug build is a different app: its own id, label and data, so
            // `make install` sits beside a release install instead of failing
            // with INSTALL_FAILED_UPDATE_INCOMPATIBLE (different signing key)
            // or replacing the copy that holds real history.
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Edge Dev"
        }
        // Flutter's plugin creates `profile` from `debug` before this block
        // runs, so it does not inherit the suffix above. Set it again, so
        // `make install-profile` is the same Edge Dev app (id, label, debug
        // key, data) at AOT speed rather than a second copy of release.
        getByName("profile") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Edge Dev"
        }
        release {
            // Use the real release key when it's configured (local key.properties or CI
            // env), otherwise fall back to debug so `flutter run --release` still works.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Upload native symbols to Crashlytics on release builds so ANR/native
            // stacks resolve to real frames instead of "root cause unknown". Pairs
            // with debugSymbolLevel=FULL above. (The Dart AOT layer — libapp.so —
            // additionally needs `flutter build … --split-debug-info=build/symbols`
            // and a `firebase crashlytics:symbols:upload` step in CI; see release
            // docs. Uncaught Dart exceptions already symbolicate via the Flutter
            // error handler — this is specifically for the sampled native/ANR path.)
            // Only configurable when the crashlytics plugin was actually applied
            // above (real google-services.json present) — otherwise this
            // extension type doesn't exist and configuring it unconditionally
            // would fail Gradle's configuration phase even with the plugin
            // block skipped.
            if (hasRealGoogleServicesJson) {
                configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                    nativeSymbolUploadEnabled = true
                }
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backs isCoreLibraryDesugaringEnabled (required by ota_update 7.x).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Native sleep-session writer. Match health 11.1.1's AndroidX version so
    // the app and plugin compile against one Health Connect API surface.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")
    // KeepAliveWorker (service watchdog). The workmanager Flutter plugin ships the
    // runtime transitively, but as an `implementation` dep it isn't visible to app
    // code at compile time — declare it explicitly for our native Worker.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    testImplementation("junit:junit:4.13.2")
}

// A real google-services.json lists the package ids it was registered for. The
// debug build's id is `<release id>.dev`; when the file has no client for it the
// plugin fails the whole debug build ("No matching client found"). Skip it for
// debug in that case: a debug install then has no Firebase, which is fine.
if (hasRealGoogleServicesJson &&
    !file("google-services.json").readText().contains("wtf.openstrap.openstrap_edge.dev")
) {
    tasks.matching { it.name == "processDebugGoogleServices" }.configureEach { enabled = false }
}
