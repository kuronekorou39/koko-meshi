# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google Maps
-keep class com.google.android.gms.maps.** { *; }

# JSON / Serialization
-keepattributes Signature
-keepattributes *Annotation*

# OkHttp / HTTP
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# Google Play Core (Flutter deferred components)
-dontwarn com.google.android.play.core.**
