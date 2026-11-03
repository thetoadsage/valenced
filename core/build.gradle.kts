plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.kmp.library)
    alias(libs.plugins.kotlin.serialization)
    `maven-publish`
}

val appleTargets = findProperty("valenced.appleTargets")?.toString() == "true" ||
    System.getProperty("os.name").equals("Mac OS X", ignoreCase = true)

kotlin {
    jvmToolchain(libs.versions.javaVersion.get().toInt())

    android {
        namespace = "app.valenced.core"
        compileSdk = libs.versions.compileSdk.get().toInt()
        minSdk = libs.versions.minSdkLibrary.get().toInt()

        withHostTest {
            // Logger wraps android.util.Log; return default values so host tests can run.
            isReturnDefaultValues = true
        }
    }

    if (appleTargets) {
        val iosArm64 = iosArm64()
        iosSimulatorArm64()

        // The tweak consumes @CName exports, which require the C library output.
        iosArm64.binaries.staticLib {
            baseName = "ValencedCore"
        }

        iosArm64.binaries.framework {
            baseName = "ValencedCore"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(libs.kotlinx.coroutines.core)
            api(libs.okio)
            api(libs.kotlinx.serialization.json)
        }

        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.okio.fakefilesystem)
        }
    }
}

// commonMain can't read BuildConfig, so the API version arrives as a generated constant.
val generateCoreConstants = tasks.register("generateCoreConstants") {
    val apiVersion = libs.versions.apiVersion.get()
    val outputDir = layout.buildDirectory.dir("generated/valenced/commonMain/kotlin")

    inputs.property("apiVersion", apiVersion)
    outputs.dir(outputDir)

    doLast {
        val file = outputDir.get().file("app/valenced/core/CoreConstants.kt").asFile
        file.parentFile.mkdirs()
        file.writeText(
            """
            package app.valenced.core

            /** The published `:android:api` version, mirrored from `gradle/libs.versions.toml`. */
            internal const val API_VERSION_STRING: String = "$apiVersion"
            """.trimIndent() + "\n"
        )
    }
}

kotlin.sourceSets.commonMain {
    kotlin.srcDir(generateCoreConstants)
}

// more cursed iOS on Linux
val isMacHost = System.getProperty("os.name").equals("Mac OS X", ignoreCase = true)
if (appleTargets && !isMacHost) {
    val konanVersion = libs.versions.kotlin.get()

    val overlayDir = rootProject.layout.projectDirectory.dir(".konan-overlay")
    val runtimeCacheDir = File(gradle.gradleUserHomeDir, "caches/valenced")

    val theosDir = providers.environmentVariable("THEOS")
        .orElse(providers.systemProperty("user.home").map { "$it/theos" })

    val tweakMakefileFile = rootProject.file("ios/Makefile")
    val tweakMakefileText = providers.provider {
        tweakMakefileFile.takeIf { it.isFile }?.readText().orEmpty()
    }
    val tweakSdkName = tweakMakefileText.map {
        Regex("(?m)^\\s*SDK\\s*=\\s*(\\S+)").find(it)?.groupValues?.get(1).orEmpty()
    }
    val tweakMinIos = tweakMakefileText.map {
        Regex("(?m)^\\s*TARGET\\s*:?=\\s*\\S+?:\\S+?:\\S+?:(\\S+)").find(it)?.groupValues?.get(1).orEmpty()
    }

    val provisionOverlay = tasks.register<Exec>("provisionKonanOverlay") {
        group = "ios"
        description = "Prepares the project-local Kotlin/Native overlay used for iOS cross-linking."
        val script = rootProject.file("gradle/ios-cross/provision-konan-overlay.sh")

        commandLine("bash", script.absolutePath)
        dependsOn("downloadKotlinNativeDistribution")
        environment("KONAN_VERSION", konanVersion)
        environment("OVERLAY_DIR", overlayDir.asFile.absolutePath)
        environment("CACHE_DIR", runtimeCacheDir.absolutePath)
        environment("THEOS", theosDir.get())
        tweakSdkName.orNull?.takeIf { it.isNotEmpty() }?.let { environment("SDK_NAME", it) }
        tweakMinIos.orNull?.takeIf { it.isNotEmpty() }?.let { environment("MIN_IOS_VERSION", it) }

        environment("FORCE_PROVISION", "1")
        inputs.file(script)
        inputs.file(rootProject.file("ios/Makefile"))
        inputs.property("theos", theosDir)
        inputs.property("sdkName", tweakSdkName.orElse(""))
        inputs.property("minIos", tweakMinIos.orElse(""))
        outputs.file(overlayDir.file(".provisioned-$konanVersion"))
    }

    val iosMain = kotlin.targets.getByName("iosArm64").compilations.getByName("main")
    val coreStaticLib = layout.buildDirectory.file("bin/iosArm64/debugStatic/libValencedCore.a")
    val overlayCompilerJar = overlayDir.file("konan/lib/kotlin-native-compiler-embeddable.jar")

    tasks.register<JavaExec>("linkValencedCoreStaticIosArm64") {
        group = "ios"
        description = "Cross-links libValencedCore.a for iOS arm64 on a non-macOS host."
        dependsOn(tasks.named("compileKotlinIosArm64"), provisionOverlay)

        inputs.files(iosMain.output.classesDirs).withPropertyName("klib")
        inputs.files(iosMain.compileDependencyFiles).withPropertyName("dependencyKlibs")
        inputs.file(overlayDir.file("konan/konan.properties")).withPropertyName("overlayProperties")
        outputs.file(coreStaticLib).withPropertyName("archive")

        classpath = files(overlayCompilerJar)
        mainClass.set("org.jetbrains.kotlin.cli.utilities.MainKt")
        jvmArgs(
            "-ea",
            "-Xmx3G",
            "-Dfile.encoding=UTF-8",
            "-Dos.name=Mac OS X",
            "-Dkonan.home=${overlayDir.asFile.absolutePath}",
        )
        environment("KONAN_USE_INTERNAL_SERVER", "1")

        argumentProviders.add(CommandLineArgumentProvider {
            val klib = iosMain.output.classesDirs.files.singleOrNull()
                ?: error("expected a single iOS klib output, got ${iosMain.output.classesDirs.files}")
            val dependencies = iosMain.compileDependencyFiles.files
                .filter { it.isFile && it.name.endsWith(".klib") }
                .sortedBy { it.absolutePath }
            buildList {
                add("konanc")
                addAll(listOf("-produce", "static", "-target", "ios_arm64"))
                add("-Xbinary=enableDebugTransparentStepping=false")
                add("-Xinclude=${klib.absolutePath}")
                addAll(listOf("-o", coreStaticLib.get().asFile.absolutePath))
                dependencies.forEach { addAll(listOf("-l", it.absolutePath)) }
            }
        })
    }

    tasks.matching {
        val name = it.name.lowercase()
        name.contains("ios") && name.contains("test")
    }.configureEach { enabled = false }
}

// Forks publish to their own repository's packages.
val githubRepository = providers.environmentVariable("GITHUB_REPOSITORY").getOrElse("Valenced/valenced")

publishing {
    publications.withType<MavenPublication>().configureEach {
        groupId = "app.valenced"
        version = libs.versions.apiVersion.get()
    }

    repositories {
        // Credentials come from the `GitHubPackagesUsername` and `GitHubPackagesPassword` Gradle properties.
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/$githubRepository")
            credentials(PasswordCredentials::class)
        }
    }
}
