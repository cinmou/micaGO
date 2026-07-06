# C62: mobile_scanner (ML Kit barcode) release-mode fix.
#
# Release builds crashed the QR scanner with an obfuscated NPE
# ("Attempt to invoke virtual method 'qc.c qc.b.a(mc.b)' on a null object
# reference") while debug builds worked — the signature of R8 full mode
# (AGP 8 default) stripping ML Kit internals. mobile_scanner's own consumer
# rules only keep `com.google.mlkit.*` (single star = one package level, so
# none of the vision/barcode subpackages) and none of the
# com.google.android.gms ML Kit internals. Keep the whole surface:
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.android.odml.image.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
