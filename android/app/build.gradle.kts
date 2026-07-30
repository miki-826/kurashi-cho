import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val householdSigning = Properties()
val householdSigningFile = rootProject.file("key.properties")
if (householdSigningFile.exists()) {
    householdSigningFile.inputStream().use(householdSigning::load)
}

android {
    namespace = "com.miki.householdai"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.miki.householdai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            val storePath = System.getenv("HOUSEHOLD_STORE_FILE")
                ?: householdSigning.getProperty("storeFile")
            if (storePath != null) {
                signingConfig = signingConfigs.create("householdRelease") {
                    storeFile = rootProject.file(storePath)
                    storePassword = System.getenv("HOUSEHOLD_STORE_PASSWORD")
                        ?: householdSigning.getProperty("storePassword")
                    keyAlias = System.getenv("HOUSEHOLD_KEY_ALIAS")
                        ?: householdSigning.getProperty("keyAlias")
                    keyPassword = System.getenv("HOUSEHOLD_KEY_PASSWORD")
                        ?: householdSigning.getProperty("keyPassword")
                }
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
}
