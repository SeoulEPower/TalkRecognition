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
import android.app.PendingIntent
import android.app.RemoteAction
import android.graphics.drawable.Icon
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.talk_recognition/tone"
    private val PIP_CHANNEL = "com.example.talk_recognition/pip"
    private val ACTION_MIC_TOGGLE = "com.example.talk_recognition.MIC_TOGGLE"
    private var toneGenerator: ToneGenerator? = null
    private var mediaPlayer: MediaPlayer? = null
    private var pipEventSink: EventChannel.EventSink? = null
    private var methodChannel: MethodChannel? = null

    private val micReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_MIC_TOGGLE) {
                methodChannel?.invokeMethod("toggleMic", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        methodChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "playChime") {
                try {
                    if (mediaPlayer == null) {
                        try {
                            mediaPlayer = MediaPlayer.create(this, R.raw.alarm)
                        } catch (e: Exception) {}
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
                    enterPipMode()
                    result.success(true)
                } else {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }

        // PiP EventChannel
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

        // 마이크 토글 BroadcastReceiver 등록
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(micReceiver, IntentFilter(ACTION_MIC_TOGGLE), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(micReceiver, IntentFilter(ACTION_MIC_TOGGLE))
        }
    }

    private fun enterPipMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val micIntent = Intent(ACTION_MIC_TOGGLE)
            micIntent.setPackage(packageName)
            val micPendingIntent = PendingIntent.getBroadcast(
                this, 0, micIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val micAction = RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_btn_speak_now),
                "마이크",
                "음성 인식 시작",
                micPendingIntent
            )

            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(1, 1))
                .setActions(listOf(micAction))
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

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(micReceiver) } catch (e: Exception) {}
    }

    private fun playFallbackTone() {
        if (toneGenerator == null) {
            toneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100)
        }
        toneGenerator?.startTone(ToneGenerator.TONE_CDMA_ABBR_ALERT, 1000)
    }
}
