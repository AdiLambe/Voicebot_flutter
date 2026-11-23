package com.ira.ira_service_desk

import android.annotation.SuppressLint
import android.content.Context
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
}
