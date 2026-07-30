package com.miki.household_ai

import android.graphics.BitmapFactory
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private val nanoScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val generativeModel by lazy { Generation.getClient() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NANO_CHANNEL,
        ).setMethodCallHandler(::handleNanoCall)
    }

    private fun handleNanoCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkStatus" -> nanoScope.launch {
                runCatching { generativeModel.checkStatus() }
                    .onSuccess { result.success(statusName(it)) }
                    .onFailure {
                        result.success("ERROR")
                    }
            }

            "downloadModel" -> nanoScope.launch {
                try {
                    when (generativeModel.checkStatus()) {
                        FeatureStatus.AVAILABLE -> result.success("AVAILABLE")
                        FeatureStatus.UNAVAILABLE -> result.success("UNAVAILABLE")
                        else -> {
                            var replied = false
                            generativeModel.download().collect { status ->
                                when (status) {
                                    DownloadStatus.DownloadCompleted -> {
                                        if (!replied) {
                                            replied = true
                                            result.success("AVAILABLE")
                                        }
                                    }

                                    is DownloadStatus.DownloadFailed -> {
                                        if (!replied) {
                                            replied = true
                                            result.success("ERROR")
                                        }
                                    }

                                    else -> Unit
                                }
                            }
                            if (!replied) result.success("ERROR")
                        }
                    }
                } catch (_: Throwable) {
                    result.success("ERROR")
                }
            }

            "warmup" -> nanoScope.launch {
                runCatching { generativeModel.warmup() }
                    .onSuccess { result.success(true) }
                    .onFailure {
                        result.error("AI_WARMUP_FAILED", "端末内AIを準備できませんでした", null)
                    }
            }

            "analyzeReceipt" -> analyzeReceipt(call, result)
            else -> result.notImplemented()
        }
    }

    private fun analyzeReceipt(call: MethodCall, result: MethodChannel.Result) {
        val imagePath = call.argument<String>("imagePath")
        val ocrText = call.argument<String>("ocrText").orEmpty()
        val categories = call.argument<String>("categories").orEmpty()
        val currentDateTime = call.argument<String>("currentDateTime").orEmpty()
        if (imagePath.isNullOrBlank()) {
            result.error("IMG_READ_FAILED", "画像を読み込めませんでした", null)
            return
        }

        nanoScope.launch {
            try {
                if (generativeModel.checkStatus() != FeatureStatus.AVAILABLE) {
                    result.error("AI_UNAVAILABLE", "この端末ではGemini Nanoを利用できません", null)
                    return@launch
                }
                val bitmap = BitmapFactory.decodeFile(imagePath)
                    ?: throw IllegalArgumentException("Image decoding failed")
                val prompt = receiptPrompt(
                    ocrText = ocrText.take(MAX_OCR_LENGTH),
                    categories = categories,
                    currentDateTime = currentDateTime,
                )
                val request = generateContentRequest(
                    ImagePart(bitmap),
                    TextPart(prompt),
                ) {
                    temperature = 0.1f
                    candidateCount = 1
                    maxOutputTokens = 2048
                }
                val response = generativeModel.generateContent(request)
                val text = response.candidates.firstOrNull()?.text
                if (text.isNullOrBlank()) {
                    result.error("AI_INVALID_OUTPUT", "解析結果を取得できませんでした", null)
                } else {
                    result.success(text)
                }
            } catch (_: Throwable) {
                result.error("AI_INFERENCE_FAILED", "端末内AIで解析できませんでした", null)
            }
        }
    }

    override fun onDestroy() {
        nanoScope.cancel()
        generativeModel.close()
        super.onDestroy()
    }

    private fun statusName(status: Int): String = when (status) {
        FeatureStatus.AVAILABLE -> "AVAILABLE"
        FeatureStatus.DOWNLOADABLE -> "DOWNLOADABLE"
        FeatureStatus.DOWNLOADING -> "DOWNLOADING"
        else -> "UNAVAILABLE"
    }

    private fun receiptPrompt(
        ocrText: String,
        categories: String,
        currentDateTime: String,
    ): String = """
        あなたは日本の家計簿アプリのレシート解析エンジンです。
        画像とOCR文字列から、実際に支払った内容だけを抽出してください。
        推測だけで商品を作らず、合計は小計・預り金・釣銭ではなく最終支払額を優先してください。
        商品合計とレシート合計が違っても値を捏造しないでください。
        出力は説明やMarkdownを付けず、次の形のJSONだけにしてください。
        {"merchant":null,"purchasedAt":null,"totalAmount":0,"paymentMethod":null,
        "items":[{"name":"商品名","quantity":1,"unitPrice":null,"amount":0,
        "categoryCode":"other","confidence":0.0}],"confidence":0.0,"warnings":[]}

        現在日時: $currentDateTime
        利用可能カテゴリ: $categories
        OCR文字列:
        $ocrText
    """.trimIndent()

    companion object {
        private const val NANO_CHANNEL = "com.miki.householdai/gemini_nano"
        private const val MAX_OCR_LENGTH = 6000
    }
}
