plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.kotlin.compose)
}

val coreDirectory = rootProject.layout.projectDirectory.dir("../client_core")
val buildNativeCore by tasks.registering(Exec::class) {
    workingDir(coreDirectory)
    commandLine("zig", "build", "android-libs", "--release=safe")
    // Always let Zig evaluate its own dependency graph, including shared packages.
}
val syncNativeLibraries by tasks.registering(Sync::class) {
    dependsOn(buildNativeCore)
    from(coreDirectory.dir("zig-out/lib/android")) {
        include("arm64-v8a/libverde_client.so", "x86_64/libverde_client.so")
    }
    into(layout.buildDirectory.dir("generated/jniLibs"))
}

android {
    namespace = "dev.verdeai.app"
    compileSdk = 35
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "dev.verdeai.app"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("generated/jniLibs"))
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isIncludeAndroidResources = true }
}

// AGP does not preserve task dependencies from the jniLibs source directory.
tasks.named("preBuild") { dependsOn(syncNativeLibraries) }

dependencies {
    implementation(libs.coroutines)
    implementation(libs.datastore)
    implementation(libs.okhttp)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.okhttp.tls)
    implementation(libs.kotlinx.serialization.json)
    implementation(platform(libs.compose.bom))
    implementation(libs.activity.compose)
    implementation(libs.compose.material3)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
