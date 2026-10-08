plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.kotlin.compose)
}

// D-14 push inputs; both optional. Without them push is disabled cleanly at runtime.
// The google-services Gradle plugin is deliberately not applied: it fails when the file is absent.
// Only the four FirebaseOptions fields are extracted; the file itself never enters the repo.
fun pushInput(name: String): String? =
    (providers.gradleProperty(name).orNull ?: providers.environmentVariable(name).orNull)?.trim()?.takeIf { it.isNotEmpty() }

data class FirebaseFields(val projectId: String, val appId: String, val apiKey: String, val senderId: String)

fun firebaseFields(applicationId: String): FirebaseFields? {
    val path = pushInput("VERDE_GOOGLE_SERVICES_JSON") ?: return null
    val file = File(path)
    require(file.isFile) { "VERDE_GOOGLE_SERVICES_JSON does not name a readable file" }
    @Suppress("UNCHECKED_CAST")
    val root = groovy.json.JsonSlurper().parse(file) as Map<String, Any?>
    val project = root["project_info"] as? Map<String, Any?> ?: error("google-services.json: missing project_info")
    @Suppress("UNCHECKED_CAST")
    val client = (root["client"] as? List<Map<String, Any?>>).orEmpty().firstOrNull { entry ->
        val info = entry["client_info"] as? Map<String, Any?>
        val android = info?.get("android_client_info") as? Map<String, Any?>
        android?.get("package_name") == applicationId
    } ?: error("google-services.json has no Android client for $applicationId")
    val appId = (client["client_info"] as Map<*, *>)["mobilesdk_app_id"] as? String
    val apiKey = ((client["api_key"] as? List<*>)?.firstOrNull() as? Map<*, *>)?.get("current_key") as? String
    val fields = FirebaseFields(project["project_id"] as? String ?: "", appId ?: "", apiKey ?: "",
        project["project_number"]?.toString() ?: "")
    require(listOf(fields.projectId, fields.appId, fields.apiKey, fields.senderId).all { it.isNotBlank() && '"' !in it && '\\' !in it }) {
        "google-services.json: project_id, mobilesdk_app_id, api_key or project_number is missing"
    }
    return fields
}

/** The relay base URL (README: `<base>/v1/register`); HTTPS only, no trailing slash. */
val pushRelayUrl: String = pushInput("VERDE_PUSH_RELAY_URL")?.trimEnd('/')?.also {
    require(Regex("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$").matches(it)) {
        "VERDE_PUSH_RELAY_URL must be an https:// base URL without query or fragment"
    }
} ?: ""
val firebase = firebaseFields("dev.verdeai.app")
fun quoted(value: String?) = "\"" + (value ?: "") + "\""

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
    compileSdk = 36
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "dev.verdeai.app"
        minSdk = 29
        targetSdk = 36
        // CI passes the run number so every Play upload is newer than the last.
        versionCode = providers.environmentVariable("VERDE_VERSION_CODE").orNull?.toInt() ?: 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        // Empty strings mean "not configured" (see PushConfig.kt).
        buildConfigField("String", "FIREBASE_PROJECT_ID", quoted(firebase?.projectId))
        buildConfigField("String", "FIREBASE_APP_ID", quoted(firebase?.appId))
        buildConfigField("String", "FIREBASE_API_KEY", quoted(firebase?.apiKey))
        buildConfigField("String", "FIREBASE_SENDER_ID", quoted(firebase?.senderId))
        buildConfigField("String", "PUSH_RELAY_URL", quoted(pushRelayUrl))
    }
    // The Play upload key comes from the environment (CI secrets); it never lives in the repo.
    // Play App Signing re-signs releases with the app key. Without the variables release is unsigned.
    val uploadKeystore = providers.environmentVariable("VERDE_UPLOAD_KEYSTORE").orNull
    signingConfigs {
        if (uploadKeystore != null) {
            create("upload") {
                storeFile = file(uploadKeystore)
                storePassword = providers.environmentVariable("VERDE_UPLOAD_KEYSTORE_PASSWORD").get()
                keyAlias = "verde-upload"
                keyPassword = storePassword
            }
        }
    }
    buildTypes {
        release { signingConfig = signingConfigs.findByName("upload") }
    }
    sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("generated/jniLibs"))
    buildFeatures {
        compose = true
        buildConfig = true
    }
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
    // Messaging only (D-14): no Analytics or Crashlytics. FirebaseApp is initialized manually.
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
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
