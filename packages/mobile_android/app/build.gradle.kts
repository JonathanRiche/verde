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

val uploadKeystore = providers.environmentVariable("VERDE_ANDROID_UPLOAD_KEYSTORE").orNull
val uploadStorePassword = providers.environmentVariable("VERDE_ANDROID_STORE_PASSWORD").orNull
val uploadKeyAlias = providers.environmentVariable("VERDE_ANDROID_KEY_ALIAS").orNull
val uploadKeyPassword = providers.environmentVariable("VERDE_ANDROID_KEY_PASSWORD").orNull
val uploadSigning = listOf(uploadKeystore, uploadStorePassword, uploadKeyAlias, uploadKeyPassword)
require(uploadSigning.all { it.isNullOrBlank() } || uploadSigning.all { !it.isNullOrBlank() }) {
    "Supply all four VERDE_ANDROID upload-signing environment variables, or none."
}
val playVersionCode = providers.environmentVariable("VERDE_ANDROID_VERSION_CODE").orNull?.let {
    requireNotNull(it.toIntOrNull()?.takeIf { value -> value in 1..2100000000 }) { "Invalid VERDE_ANDROID_VERSION_CODE" }
} ?: 1

android {
    namespace = "dev.verdeai.app"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "dev.verdeai.app"
        minSdk = 29
        targetSdk = 36
        versionCode = playVersionCode
        versionName = providers.environmentVariable("VERDE_ANDROID_VERSION_NAME").orElse("0.1.0").get()
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    if (!uploadKeystore.isNullOrBlank()) {
        signingConfigs.create("upload") {
            storeFile = file(uploadKeystore)
            storePassword = uploadStorePassword
            keyAlias = uploadKeyAlias
            keyPassword = uploadKeyPassword
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("upload")
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

// Host-JVM build of the same core with the JNI exports, for JNI-level unit tests.
val buildJvmCore by tasks.registering(Exec::class) {
    workingDir(coreDirectory)
    commandLine("zig", "build", "jvm-lib", "--release=safe")
}
tasks.withType<Test>().configureEach {
    dependsOn(buildJvmCore)
    systemProperty("java.library.path", coreDirectory.dir("zig-out/lib/jvm").asFile.absolutePath)
    systemProperty("verde.core.fixtures", coreDirectory.dir("src/fixtures").asFile.absolutePath)
}

dependencies {
    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    implementation(libs.camera.view)
    implementation(libs.barcode.scanning)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.navigation.compose)
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
