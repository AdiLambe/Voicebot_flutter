package com.ira.ira_service_desk

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.telecom.TelecomManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Phone lock ho tab bhi call screen ke upar app dikhe
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ira/phone").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "callState" -> {
                        val p = getSharedPreferences(CallReceiver.PREFS, Context.MODE_PRIVATE)
                        result.success(
                            mapOf(
                                "state" to (p.getString("state", "IDLE") ?: "IDLE"),
                                "number" to (p.getString("number", "") ?: ""),
                                "ts" to p.getLong("ts", 0L)
                            )
                        )
                    }
                    "answer" -> result.success(answerCall())
                    "end" -> result.success(endCall())
                    "speaker" -> {
                        setSpeaker(call.arguments as? Boolean ?: false)
                        result.success(true)
                    }
                    "toBack" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    "recStart" -> result.success(startRecording())
                    "recStop" -> result.success(stopRecording())
                    "recPath" -> result.success(recPath)
                    "recSource" -> result.success(recSource)
                    "play" -> {
                        val a = call.arguments as Map<*, *>
                        result.success(play(a["path"] as String, (a["ms"] as? Int) ?: 0))
                    }
                    "stopPlay" -> {
                        stopPlay()
                        result.success(true)
                    }
                    "recorderEnabled" -> result.success(recorderServiceEnabled())
                    "openAccessibility" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.success(false)
            }
        }
    }

    private fun telecom(): TelecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager

    @SuppressLint("MissingPermission")
    private fun answerCall(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        return try {
            @Suppress("DEPRECATION")
            telecom().acceptRingingCall()
            true
        } catch (e: Exception) {
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun endCall(): Boolean {
        if (Build.VERSION.SDK_INT < 28) return false
        return try {
            @Suppress("DEPRECATION")
            telecom().endCall()
        } catch (e: Exception) {
            false
        }
    }

    /** Bot ki awaaz customer tak pahunche isliye speaker on + volume full. */
    private fun setSpeaker(on: Boolean) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= 31) {
            if (on) {
                val dev = am.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (dev != null) am.setCommunicationDevice(dev)
            } else {
                am.clearCommunicationDevice()
            }
        }
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = on
        if (on) {
            for (stream in intArrayOf(AudioManager.STREAM_VOICE_CALL, AudioManager.STREAM_MUSIC)) {
                try {
                    am.setStreamVolume(stream, am.getStreamMaxVolume(stream), 0)
                } catch (e: Exception) {
                }
            }
        }
    }

    // ================= Call recording =================
    // Android normal apps ko call ki awaaz nahi deta. Call-recorder apps ki tarah:
    // accessibility service on + speaker on + sabse achha mic source try karo.
    private var recorder: MediaRecorder? = null
    private var recPath: String? = null
    private var recSource: String? = null
    private var player: MediaPlayer? = null
    private val main = Handler(Looper.getMainLooper())

    private fun sources(): List<Pair<Int, String>> {
        val l = mutableListOf(
            MediaRecorder.AudioSource.VOICE_CALL to "VOICE_CALL",
            MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION"
        )
        if (Build.VERSION.SDK_INT >= 24) l.add(MediaRecorder.AudioSource.UNPROCESSED to "UNPROCESSED")
        l.add(MediaRecorder.AudioSource.MIC to "MIC")
        return l
    }

    private fun newRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()

    /** Recording shuru. Return: file path (null = koi source nahi chala). */
    private fun startRecording(): String? {
        stopRecording()
        val dir = File(getExternalFilesDir(null) ?: filesDir, "calls").apply { mkdirs() }
        val name = "IRA_call_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        return tryFrom(0, dir, name)
    }

    private fun tryFrom(start: Int, dir: File, name: String): String? {
        val list = sources()
        for (i in start until list.size) {
            val (src, label) = list[i]
            val f = File(dir, "${name}_$label.m4a")
            val r = newRecorder()
            try {
                r.setAudioSource(src)
                r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                r.setAudioSamplingRate(44100)
                r.setAudioEncodingBitRate(96000)
                r.setOutputFile(f.absolutePath)
                r.prepare()
                r.start()
                recorder = r
                recPath = f.absolutePath
                recSource = label
                // Kuch phones VOICE_CALL "chalu" kar dete hain par khamoshi record karte hain:
                // 2.5 sec baad level 0 ho toh agla source try karo.
                if (i < list.size - 1) {
                    main.postDelayed({ try { r.maxAmplitude } catch (e: Exception) {} }, 300)
                    main.postDelayed({
                        if (recorder === r) {
                            val amp = try { r.maxAmplitude } catch (e: Exception) { 0 }
                            if (amp == 0) {
                                try { r.stop() } catch (e: Exception) {}
                                r.release()
                                f.delete()
                                recorder = null
                                tryFrom(i + 1, dir, name)
                            }
                        }
                    }, 2500)
                }
                return f.absolutePath
            } catch (e: Exception) {
                try { r.release() } catch (e2: Exception) {}
                f.delete()
            }
        }
        recPath = null
        recSource = null
        return null
    }

    /** Recording band. Return: final file path. Copy phone ke Music/IRA-Calls mein bhi. */
    private fun stopRecording(): String? {
        val r = recorder ?: return null
        recorder = null
        try { r.stop() } catch (e: Exception) {}
        try { r.release() } catch (e: Exception) {}
        val p = recPath
        if (p != null) publishToMusic(File(p))
        return p
    }

    private fun publishToMusic(f: File) {
        if (Build.VERSION.SDK_INT < 29 || !f.exists()) return
        try {
            val v = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, f.name)
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
                put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/IRA-Calls")
            }
            val uri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, v) ?: return
            contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
        } catch (e: Exception) {
        }
    }

    private fun play(path: String, ms: Int): Boolean {
        stopPlay()
        return try {
            val m = MediaPlayer()
            m.setDataSource(path)
            m.prepare()
            if (ms > 0) m.seekTo(ms)
            m.start()
            m.setOnCompletionListener { stopPlay() }
            player = m
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopPlay() {
        val m = player ?: return
        player = null
        try { m.stop() } catch (e: Exception) {}
        try { m.release() } catch (e: Exception) {}
    }

    private fun recorderServiceEnabled(): Boolean {
        val on = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return on.split(':').any { it.startsWith("$packageName/") && it.endsWith("IraRecorderService") }
    }
}

/**
 * "IRA Call Recorder" accessibility service. Kuch karti nahi - bas iske on hone se
 * Android 10+ call ke dauraan app ko mic se recording karne deta hai
 * (call-recorder apps yahi tarika use karte hain).
 */
class IraRecorderService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        serviceInfo = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 1000
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}
}
