package com.example.talk_recognition

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.media.AudioManager
import android.media.ToneGenerator

import android.media.MediaPlayer
import java.util.ArrayList
import java.util.HashMap
import android.content.Intent
import android.app.PictureInPictureParams
import android.util.Rational
import android.os.Build
import android.content.res.Configuration

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.talk_recognition/tone"
    private val PIP_CHANNEL = "com.example.talk_recognition/pip"
    private var toneGenerator: ToneGenerator? = null
    private var mediaPlayer: MediaPlayer? = null
    private var pipEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "playChime") {
                // Try playing custom alarm.wav
                try {
                    // Create new instance or reuse? Better create new to ensure fresh start from beginning
                    // But creating every 2s is heavy. 
                    // Let's create once if null or not playing?
                    // Actually alarm loop calls this every 2s. 
                    // If playing, we might restart?
                    // Let's reuse if possible, or create new.
                    if (mediaPlayer == null) {
                        try {
                            mediaPlayer = MediaPlayer.create(this, R.raw.alarm)
                        } catch (e: Exception) {
                            // Resource might be invalid (dummy file)
                        }
                    }
                    
                    if (mediaPlayer != null) {
                        if (mediaPlayer!!.isPlaying) {
                            mediaPlayer!!.seekTo(0)
                        }
                        mediaPlayer!!.start()
                    } else {
                        playFallbackTone()
                    }
                } catch (e: Exception) {
                    playFallbackTone()
                }
                result.success(null)
            } else if (call.method == "stopChime") {
                try {
                    mediaPlayer?.stop()
                    mediaPlayer?.release()
                    mediaPlayer = null
                } catch (e: Exception) {}

                toneGenerator?.stopTone()
                toneGenerator?.release()
                toneGenerator = null
                result.success(null)
            } else if (call.method == "getInstalledApps") {
                val pm = packageManager
                val apps = pm.getInstalledApplications(android.content.pm.PackageManager.GET_META_DATA)
                val list = ArrayList<Map<String, String>>()
                for (app in apps) {
                    val launchIntent = pm.getLaunchIntentForPackage(app.packageName)
                    if (launchIntent != null) {
                        val map = HashMap<String, String>()
                        map["appName"] = pm.getApplicationLabel(app).toString()
                        map["packageName"] = app.packageName
                        list.add(map)
                    }
                }
                result.success(list)
            } else if (call.method == "launchApp") {
                val packageName = call.argument<String>("packageName")
                if (packageName != null) {
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    if (launchIntent != null) {
                        startActivity(launchIntent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Package name is null", null)
                }
            } else if (call.method == "getTimezone") {
                val timeZone = java.util.TimeZone.getDefault()
                result.success(timeZone.id)
            } else if (call.method == "sendSms") {
                val phone = call.argument<String>("phone")
                val message = call.argument<String>("message")
                if (phone != null && message != null) {
                    try {
                        val smsManager = android.telephony.SmsManager.getDefault()
                        // 긴 메시지는 분할 전송
                        val parts = smsManager.divideMessage(message)
                        if (parts.size > 1) {
                            smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
                        } else {
                            smsManager.sendTextMessage(phone, null, message, null, null)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Phone or message is null", null)
                }
            } else if (call.method == "shareToApp") {
                val packageName = call.argument<String>("packageName")
                val text = call.argument<String>("text")
                if (packageName != null && text != null) {
                    try {
                        val sendIntent = Intent().apply {
                            action = Intent.ACTION_SEND
                            putExtra(Intent.EXTRA_TEXT, text)
                            type = "text/plain"
                            setPackage(packageName)
                        }
                        startActivity(sendIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Package name or text is null", null)
                }
            } else if (call.method == "enterPip") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val params = PictureInPictureParams.Builder()
                        .setAspectRatio(Rational(1, 1))
                        .build()
                    enterPictureInPictureMode(params)
                    result.success(true)
                } else {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }

        // PiP EventChannel - Flutter에 PiP 상태 변경 알림
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pipEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    pipEventSink = null
                }
            }
        )
    }

    private fun enterPipMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(1, 1))
                .build()
            enterPictureInPictureMode(params)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        enterPipMode()
    }

    override fun onPictureInPictureModeChanged(isInPipMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPipMode, newConfig)
        pipEventSink?.success(isInPipMode)
    }

    private fun playFallbackTone() {
        if (toneGenerator == null) {
            toneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100)
        }
        toneGenerator?.startTone(ToneGenerator.TONE_CDMA_ABBR_ALERT, 1000)
    }
}
