package com.example.review_app

import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsEngineName: String? = null
    private val lineIds = AtomicInteger(0)

    /** Voice, speed and pitch are the user's choice, so they are remembered. */
    private val prefs by lazy { getSharedPreferences("speech", MODE_PRIVATE) }

    /**
     * The range the engine is asked to stay inside. Android rejects a rate or
     * pitch outside it by refusing the call, so anything further away is stored
     * clamped and the sliders cannot reach it.
     */
    private val minRate = 0.5f
    private val maxRate = 2.0f
    private val minPitch = 0.5f
    private val maxPitch = 2.0f

    /** Replies waiting for the speech engine to finish initialising. */
    private val waitingForEngine = mutableListOf<(String?) -> Unit>()

    /** One reply per utterance, completed when that utterance ends. */
    private val speaking = mutableMapOf<String, (Boolean) -> Unit>()

    /** The first line is held here, because the engine is not ready yet. */
    private var heldWhileInitialising: Pair<String, (Boolean) -> Unit>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // The engine ships as a native library and is extracted to
        // nativeLibraryDir, because Android refuses to run a binary left in the
        // app's own data directory. That path is not derivable in Dart, so the
        // app asks for it here.
        MethodChannel(messenger, "$packageName/native_library_dir")
            .setMethodCallHandler { _, result ->
                result.success(applicationInfo.nativeLibraryDir)
            }

        MethodChannel(messenger, "$packageName/tts").setMethodCallHandler { call, result ->
            handle(call, result)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engineName" -> {
                if (ttsReady) {
                    result.success(ttsEngineName)
                } else {
                    waitingForEngine.add { name -> result.success(name) }
                    ensureEngine()
                }
            }
            "speak" -> handleSpeak(call.argument<String>("text")) { ok ->
                result.success(ok)
            }
            "stop" -> {
                stopSpeaking()
                result.success(null)
            }
            "voices" -> withEngine(result) { engine -> result.success(voicesFor(engine)) }
            "settings" -> withEngine(result) { _ ->
                result.success(
                    mapOf(
                        "rate" to storedRate().toDouble(),
                        "pitch" to storedPitch().toDouble(),
                    )
                )
            }
            "setVoice" -> withEngine(result) { engine ->
                val wanted = call.argument<String>("name")
                result.success(applyVoice(engine, wanted))
            }
            "setRate" -> withEngine(result) { engine ->
                val rate = stored("rate", call.argument<Double>("rate"), 1.0f, minRate, maxRate)
                result.success(engine.setSpeechRate(rate) == TextToSpeech.SUCCESS)
            }
            "setPitch" -> withEngine(result) { engine ->
                val pitch =
                    stored("pitch", call.argument<Double>("pitch"), 1.0f, minPitch, maxPitch)
                result.success(engine.setPitch(pitch) == TextToSpeech.SUCCESS)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Remembers [value] under [key], clamped to what the engine accepts.
     *
     * The clamped value is what is stored, so a value the engine rejected is
     * never read back and applied again on the next launch.
     */
    private fun stored(
        key: String,
        value: Double?,
        fallback: Float,
        min: Float,
        max: Float,
    ): Float {
        val stored = (value?.toFloat() ?: prefs.getFloat(key, fallback)).coerceIn(min, max)
        prefs.edit().putFloat(key, stored).apply()
        return stored
    }

    /** The remembered speed, read back through the same clamp as when set. */
    private fun storedRate(): Float = stored("rate", null, 1.0f, minRate, maxRate)

    private fun storedPitch(): Float = stored("pitch", null, 1.0f, minPitch, maxPitch)

    /** Runs [action] once the engine is up, or answers with a null name. */
    private fun withEngine(result: MethodChannel.Result, action: (TextToSpeech) -> Unit) {
        if (ttsReady && tts != null) {
            action(tts!!)
            return
        }
        waitingForEngine.add { name ->
            val engine = tts
            if (name == null || engine == null) result.success(null) else action(engine)
        }
        ensureEngine()
    }

    /**
     * The English voices installed on the device, best first, with the one that
     * is speaking now at the top so the picker opens on the current choice.
     *
     * A voice that needs a connection is only offered while there is one,
     * because picking it offline would leave the app silent.
     */
    private fun voicesFor(engine: TextToSpeech): List<Map<String, Any>> {
        val selected = prefs.getString("voice", null)
        val online = isOnline()
        val voices = mutableListOf<Map<String, Any>>()
        for (voice in engine.voices) {
            if (voice.locale.language != "en") continue
            if (voice.isNetworkConnectionRequired && !online) continue
            voices.add(
                mapOf(
                    "name" to voice.name,
                    "locale" to voice.locale.toLanguageTag(),
                    "quality" to qualityName(voice.quality),
                    "score" to voice.quality,
                    "network" to voice.isNetworkConnectionRequired,
                    // Android exposes no public per-voice availability probe.
                    // Voices returned here are candidates; setVoice below is
                    // the supported operation that confirms one can be used.
                    "available" to true,
                    "selected" to (voice.name == selected),
                )
            )
        }
        voices.sortWith(
            compareByDescending<Map<String, Any>> { it["selected"] as Boolean }
                .thenBy { it["network"] as Boolean }
                .thenByDescending { it["score"] as Int }
                .thenBy { it["name"] as String }
        )
        return voices
    }

    /** The engine's numeric quality, named the way the picker shows it. */
    private fun qualityName(score: Int): String = when {
        score >= 400 -> "High"
        score >= 300 -> "Enhanced"
        score >= 200 -> "Normal"
        else -> "Low"
    }

    /**
     * Points the engine at [wanted], remembering it if the engine accepted it.
     *
     * A voice that is no longer installed, or one the engine refuses, is
     * forgotten and the default voice is left speaking.
     */
    private fun applyVoice(engine: TextToSpeech, wanted: String?): Boolean {
        var chosen: Voice? = null
        for (voice in engine.voices) {
            if (voice.name == wanted) {
                chosen = voice
                break
            }
        }
        val editor = prefs.edit()
        if (chosen == null) {
            editor.remove("voice").apply()
            return false
        }
        if (engine.setVoice(chosen) != TextToSpeech.SUCCESS) {
            editor.remove("voice").apply()
            return false
        }
        engine.setSpeechRate(storedRate())
        engine.setPitch(storedPitch())
        editor.putString("voice", chosen.name).apply()
        return true
    }

    private fun isOnline(): Boolean {
        val manager = getSystemService(android.net.ConnectivityManager::class.java)
        val network = manager?.activeNetwork ?: return false
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun handleSpeak(text: String?, reply: (Boolean) -> Unit) {
        if (text.isNullOrBlank()) {
            reply(false)
            return
        }
        if (ttsReady) {
            speakNow(text, reply)
            return
        }
        // Without this the very first line would be lost while the engine warms
        // up, which is exactly the line a user notices is missing.
        heldWhileInitialising = text to reply
        ensureEngine()
    }

    private fun speakNow(text: String, reply: (Boolean) -> Unit) {
        val engine = tts
        if (engine == null) {
            reply(false)
            return
        }
        val id = "review_app_${lineIds.incrementAndGet()}"
        speaking[id] = reply
        if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.ERROR) {
            speaking.remove(id)
            reply(false)
        }
    }

    private fun stopSpeaking() {
        tts?.stop()
        val pending: List<(Boolean) -> Unit> = speaking.values.toList()
        speaking.clear()
        for (index in 0 until pending.size) {
            pending[index](false)
        }
    }

    private fun ensureEngine() {
        if (tts != null) return
        tts = TextToSpeech(applicationContext, TextToSpeech.OnInitListener { status ->
            onEngineReady(status)
        })
    }

    private fun onEngineReady(status: Int) {
        val engine = tts
        // The framework can be present with no voice data downloaded, which is
        // what makes TTS accept calls and then stay silent.
        val available = status == TextToSpeech.SUCCESS &&
            engine != null &&
            engine.isLanguageAvailable(Locale.US) >= TextToSpeech.LANG_AVAILABLE

        if (!available) {
            ttsReady = false
            ttsEngineName = null
            resolveWaiting(null)
            return
        }

        engine?.setLanguage(Locale.US)
        // The chosen voice, speed and pitch come back on every launch, so the
        // review sounds the same as it did last time.
        applyVoice(engine, prefs.getString("voice", null))
        engine?.setSpeechRate(storedRate())
        engine?.setPitch(storedPitch())
        engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit

            override fun onDone(utteranceId: String?) {
                if (utteranceId != null) speaking.remove(utteranceId)?.let { done -> done(true) }
            }

            @Deprecated("Required by the base class")
            override fun onError(utteranceId: String?) {
                if (utteranceId != null) speaking.remove(utteranceId)?.let { done -> done(false) }
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                if (utteranceId != null) speaking.remove(utteranceId)?.let { done -> done(false) }
            }
        })
        ttsReady = true
        ttsEngineName = engine?.defaultEngine ?: "system"
        resolveWaiting(ttsEngineName)
    }

    private fun resolveWaiting(name: String?) {
        val waiting: List<(String?) -> Unit> = waitingForEngine.toList()
        waitingForEngine.clear()
        for (index in 0 until waiting.size) {
            waiting[index](name)
        }

        val held = heldWhileInitialising
        heldWhileInitialising = null
        if (held == null) return
        if (name == null) held.second(false) else speakNow(held.first, held.second)
    }

    override fun onDestroy() {
        stopSpeaking()
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        super.onDestroy()
    }
}
