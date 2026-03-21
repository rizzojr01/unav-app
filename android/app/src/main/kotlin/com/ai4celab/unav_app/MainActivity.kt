package com.ai4celab.unav_app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val arMethodChannelName = "unav/tracking/ar_method"
    private val arPoseEventChannelName = "unav/tracking/ar_pose_stream"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, arMethodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapabilities" -> result.success(
                        mapOf(
                            "backend" to "androidArCore",
                            "isSupported" to false
                        )
                    )
                    "startSession", "stopSession" -> result.success(null)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, arPoseEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {}

                override fun onCancel(arguments: Any?) {}
            })
    }
}
