# The app only exposes Japanese OCR. The Flutter ML Kit bridge references
# optional models for other writing systems, which are intentionally not packaged.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.korean.**
