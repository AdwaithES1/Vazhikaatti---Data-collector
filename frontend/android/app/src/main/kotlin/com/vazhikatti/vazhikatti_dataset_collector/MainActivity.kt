package com.vazhikatti.vazhikatti_dataset_collector

import android.content.Context
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vazhikatti.vazhikatti_dataset_collector/camera_info"
    private val TAG = "CameraInfoPlatform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCameraCharacteristicsList" -> {
                    try {
                        val cameras = getCameraCharacteristicsList()
                        result.success(cameras)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to get camera characteristics: ${e.message}", e)
                        result.error("CAMERA_INFO_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getCameraCharacteristicsList(): List<Map<String, Any?>> {
        val cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return emptyList()

        val results = mutableListOf<Map<String, Any?>>()
        val visitedIds = mutableSetOf<String>()

        try {
            val cameraIds = cameraManager.cameraIdList
            val allIdsToInspect = mutableListOf<String>()
            allIdsToInspect.addAll(cameraIds)

            // Also check for physical cameras exposed via logical multi-cameras (API 28+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                for (id in cameraIds) {
                    try {
                        val chars = cameraManager.getCameraCharacteristics(id)
                        for (pId in chars.physicalCameraIds) {
                            if (!allIdsToInspect.contains(pId)) {
                                allIdsToInspect.add(pId)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to read physical camera IDs for camera $id: ${e.message}")
                    }
                }
            }

            for (id in allIdsToInspect) {
                if (visitedIds.contains(id)) continue
                visitedIds.add(id)

                try {
                    val chars = cameraManager.getCameraCharacteristics(id)
                    val map = extractCharacteristics(id, chars)
                    results.add(map)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to get characteristics for camera $id: ${e.message}")
                }
            }
        } catch (e: CameraAccessException) {
            Log.e(TAG, "CameraAccessException while listing cameras: ${e.message}", e)
        } catch (e: Exception) {
            Log.e(TAG, "Exception while listing cameras: ${e.message}", e)
        }

        return results
    }

    private fun extractCharacteristics(id: String, chars: CameraCharacteristics): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        map["cameraId"] = id

        // Lens facing
        val lensFacing = chars.get(CameraCharacteristics.LENS_FACING)
        val lensFacingStr = when (lensFacing) {
            CameraMetadata.LENS_FACING_FRONT -> "front"
            CameraMetadata.LENS_FACING_BACK -> "back"
            CameraMetadata.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }
        map["lensFacing"] = lensFacingStr

        // Sensor orientation
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION)
        map["sensorOrientation"] = sensorOrientation

        // Focal lengths (mm)
        val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focalLengthList = focalLengths?.map { it.toDouble() } ?: emptyList<Double>()
        map["focalLengths"] = focalLengthList

        // Sensor physical size (mm)
        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val sensorWidth = sensorSize?.width?.toDouble()
        val sensorHeight = sensorSize?.height?.toDouble()
        map["sensorPhysicalWidth"] = sensorWidth
        map["sensorPhysicalHeight"] = sensorHeight

        // Pixel array size
        val pixelArraySize = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        map["pixelArrayWidth"] = pixelArraySize?.width
        map["pixelArrayHeight"] = pixelArraySize?.height

        // Apertures
        val apertures = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
        map["apertures"] = apertures?.map { it.toDouble() } ?: emptyList<Double>()

        // Minimum focus distance
        val minFocusDist = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
        map["minimumFocusDistance"] = minFocusDist?.toDouble()

        // Hardware level
        val hwLevel = chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
        val hwLevelStr = when (hwLevel) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
            else -> "UNKNOWN"
        }
        map["hardwareLevel"] = hwLevelStr

        // Capabilities & Logical Multi-Camera
        var isLogicalMulti = false
        val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
        val capList = caps?.toList() ?: emptyList()
        map["capabilities"] = capList

        val physicalIdsList = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            if (capList.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)) {
                isLogicalMulti = true
            }
            chars.physicalCameraIds?.let {
                physicalIdsList.addAll(it)
            }
        }
        map["isLogicalMultiCamera"] = isLogicalMulti
        map["physicalCameraIds"] = physicalIdsList

        // Compute FOV if focal length and sensor size are available
        if (focalLengthList.isNotEmpty() && sensorWidth != null && sensorHeight != null && sensorWidth > 0 && sensorHeight > 0) {
            val minFocal = focalLengthList.minOrNull() ?: focalLengthList[0]
            if (minFocal > 0) {
                val diagonal = sqrt(sensorWidth * sensorWidth + sensorHeight * sensorHeight)
                val hFov = 2.0 * atan(sensorWidth / (2.0 * minFocal)) * 180.0 / Math.PI
                val dFov = 2.0 * atan(diagonal / (2.0 * minFocal)) * 180.0 / Math.PI
                val focal35mm = minFocal * 43.2666 / diagonal
                map["horizontalFov"] = hFov
                map["diagonalFov"] = dFov
                map["focalLength35mm"] = focal35mm
            }
        }

        return map
    }
}
