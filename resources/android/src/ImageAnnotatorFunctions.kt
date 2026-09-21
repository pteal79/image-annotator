package com.pteal79.plugins.imageannotator

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.bridge.BridgeFunction
import com.nativephp.mobile.bridge.BridgeResponse
import java.io.File

/** Image annotation editor. Namespace: "ImageAnnotator.*" */
object ImageAnnotatorFunctions {
    private const val TAG = "Pteal79ImageAnnotator"

    private fun Map<String, Any>.string(key: String): String? {
        val value = this[key] as? String ?: return null
        return value.ifBlank { null }
    }

    /**
     * Presents the editor over a local image and returns straight away.
     * The result arrives later as exactly one Saved, Cancelled or Failed event.
     * Parameters:
     *   - imagePath: string - local JPEG or PNG (required)
     *   - originalPath: string - local original; enables Revert (optional)
     *   - id: string - echoed back in every event (required)
     */
    class Open(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val id = parameters.string("id").orEmpty()
            val imagePath = parameters.string("imagePath")
            val originalPath = parameters.string("originalPath")

            if (imagePath == null || !File(imagePath).isFile) {
                AnnotatorSession.reject(activity, id, "Couldn't load the image.")
                return BridgeResponse.success(mapOf("opened" to false))
            }

            val request = AnnotatorSession.Request(id, imagePath, originalPath)
            if (!AnnotatorSession.begin(activity, request)) {
                AnnotatorSession.reject(activity, id, AnnotatorSession.MESSAGE_ALREADY_OPEN)
                return BridgeResponse.success(mapOf("opened" to false))
            }

            Handler(Looper.getMainLooper()).post {
                try {
                    activity.startActivity(Intent(activity, AnnotatorActivity::class.java))
                } catch (e: Exception) {
                    Log.e(TAG, "Could not open the editor", e)
                    AnnotatorSession.failed(request, e.message ?: "Couldn't open the editor.")
                }
            }

            return BridgeResponse.success(mapOf("opened" to true))
        }
    }
}
