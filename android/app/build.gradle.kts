import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Release-Signatur: liegt außerhalb des Repos (Standard ~/.thisdog/android-release.properties, sonst Pfad in THISDOG_SIGNING)
// mit storeFile, storePassword, keyAlias, keyPassword. Fehlt die Datei, wird mit dem Debug-Schlüssel signiert –
// gut für den Emulator, aber so gebaute APKs lassen sich nicht über eine echt signierte App installieren.
val signingFile = file(System.getenv("THISDOG_SIGNING") ?: "${System.getProperty("user.home")}/.thisdog/android-release.properties")
val signingProps = Properties()
if (signingFile.isFile) signingFile.inputStream().use { signingProps.load(it) }
val hasReleaseKey = signingFile.isFile

android {
    namespace = "app.thisdog"
    compileSdk = 37
    defaultConfig {
        applicationId = "app.thisdog"
        minSdk = 29
        targetSdk = 36
        versionCode = 11
        versionName = "1.10"
    }
    buildFeatures { compose = true; buildConfig = true }
    signingConfigs {
        if (hasReleaseKey) create("release") {
            storeFile = file(signingProps.getProperty("storeFile") ?: error("storeFile fehlt in $signingFile"))
            storePassword = signingProps.getProperty("storePassword")
            keyAlias = signingProps.getProperty("keyAlias")
            keyPassword = signingProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else {
                // quiet statt warn: auch mit `gradlew -q` sichtbar.
                logger.quiet("WARNUNG: Keine Release-Signatur gefunden ($signingFile). Der Release-Build wird mit dem DEBUG-Schlüssel signiert – nicht verteilen.")
                signingConfigs.getByName("debug")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(bom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("com.squareup.okhttp3:okhttp:5.5.0")
    implementation("com.google.zxing:core:3.5.4")
    implementation("androidx.browser:browser:1.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("org.maplibre.gl:android-sdk:13.7.1")
    // Food-Check: Strichcode und Bilderkennung, beide mit Modell in der App (kein Google-Dienst, nichts verlässt das Telefon).
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("com.google.mlkit:image-labeling:17.0.9")
    testImplementation("com.squareup.okhttp3:mockwebserver:5.5.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
