// ---------- build.gradle.kts (android/app) ----------
import java.util.Properties
import java.io.FileInputStream
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名参数（位于项目根目录 key.properties）
val keystoreProps = Properties().apply {
    val f = rootProject.file("android/key.properties")
    if (!f.exists()) {
        throw GradleException("Missing key.properties at project root. Please create it.")
    }
    load(FileInputStream(f))
}
fun p(name: String): String =
    keystoreProps.getProperty(name) ?: throw GradleException("`$name` is missing in key.properties")

android {
    namespace = "com.ai4celab.unav_app"
    compileSdk = flutter.compileSdkVersion
    // 可留空让 Flutter 处理；若想固定 NDK，可保留下一行：
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.ai4celab.unav_app"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 正式签名配置（使用 key.properties）
    signingConfigs {
        create("release") {
            // 关键：用 rootProject.file 来解析 key.properties 中的相对路径
            storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
            storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias")
            keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // ✅ 开启代码压缩 + 资源压缩
            isMinifyEnabled = true
            isShrinkResources = true

            // 使用默认的优化规则 + 你的自定义规则（文件需要存在，可以空文件）
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // ✅ 使用 release 签名
            signingConfig = signingConfigs.getByName("release")
        }
    }

}

dependencies {
    implementation("com.google.ar:core:1.33.0")
}

flutter {
    source = "../.."
}
