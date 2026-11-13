// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Android Gradle settings (Flutter 3.29+).
//
// ВАЖНО: order репозиториев здесь критичен.
// Раньше первым был gradlePluginPortal(), который для kotlin-compiler-embeddable
// делает redirect на github.com/JetBrains/kotlin/releases/... — на GitHub
// Actions это регулярно падает с "github.com: No address associated with hostname".
//
// Мы убрали gradlePluginPortal() из pluginManagement и
// dependencyResolutionManagement. Всё нужное (AGP, Kotlin, plugin-loader)
// есть на google() + mavenCentral().

pluginManagement {
    val flutterSdkPath: String = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val path = properties.getProperty("flutter.sdk")
        require(path != null) { "flutter.sdk not set in local.properties" }
        path
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Порядок: localMaven → google → mavenCentral → gradlePluginPortal (fallback).
        mavenLocal()
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        // gradlePluginPortal оставляем последним — только как fallback,
        // если чего-то нет в google/mavenCentral.
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Flutter 3.47 requires Android Gradle Plugin 8.11.1 or newer.
    id("com.android.application") version "8.11.1" apply false
    id("com.android.library") version "8.11.1" apply false
    // Kotlin version required by the current Flutter Gradle plugin.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
