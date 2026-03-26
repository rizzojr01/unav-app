# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /Users/bibektimilsina/sdk/flutter/packages/flutter_tools/gradle/proguard-android.txt
# You can edit the include path and maintain your own separate ProGuard configuration.

# Flutter ProGuard Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# For ARCore
-keep class com.google.ar.core.** { *; }

# Ignore missing Play Store Split Install and Tasks classes (Deferred Components)
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
