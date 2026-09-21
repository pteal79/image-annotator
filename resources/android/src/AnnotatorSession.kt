package com.pteal79.plugins.imageannotator

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.ui.nativerender.NativeElementBridge
import com.nativephp.mobile.utils.NativeActionCoordinator
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * The one editor that may be open, and the single event it ends with.
 * begin() may be called off the main thread, so state changes are synchronized.
 */
object AnnotatorSession {
    private const val TAG = "Pteal79ImageAnnotator"

    const val EVENT_SAVED = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationSaved"
    const val EVENT_CANCELLED = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationCancelled"
    const val EVENT_FAILED = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationFailed"

    const val MESSAGE_ALREADY_OPEN = "already open"

    class Request(val id: String, val imagePath: String, val originalPath: String?)

    /** Editor state kept across activity re-creation. */
    class State(val editor: AnnotatorEditor, val renderer: AnnotatorRenderer) {
        var image: Bitmap? = null
    }

    var request: Request? = null
        private set

    var state: State? = null

    private var host: WeakReference<FragmentActivity>? = null

    /** Returns false when an editor is already open. */
    @Synchronized
    fun begin(activity: FragmentActivity, next: Request): Boolean {
        if (request != null) return false
        request = next
        state = null
        host = WeakReference(activity)
        return true
    }

    fun saved(owner: Request, outputPath: String, width: Int, height: Int, reverted: Boolean) {
        finish(
            owner,
            EVENT_SAVED,
            JSONObject()
                .put("outputPath", outputPath)
                .put("width", width)
                .put("height", height)
                .put("reverted", reverted)
        )
    }

    fun cancelled(owner: Request) = finish(owner, EVENT_CANCELLED, JSONObject())

    fun failed(owner: Request, message: String) = finish(owner, EVENT_FAILED, JSONObject().put("message", message))

    /**
     * Sends the session's single event. Calls for a request that is no longer
     * the open one (already finished, or replaced by a newer open) are ignored.
     */
    @Synchronized
    private fun finish(owner: Request, event: String, payload: JSONObject) {
        val current = request ?: return
        if (current !== owner) return
        request = null
        state = null
        val activity = host?.get()
        host = null
        dispatch(activity, event, payload.put("id", current.id))
    }

    /** Fails a request that never became the session (bad input, or already open). */
    fun reject(activity: FragmentActivity, id: String, message: String) {
        dispatch(activity, EVENT_FAILED, JSONObject().put("id", id).put("message", message))
    }

    /** Events go out on the main thread, after the editor has been dismissed. */
    private fun dispatch(activity: FragmentActivity?, event: String, payload: JSONObject) {
        val json = payload.toString()
        Handler(Looper.getMainLooper()).post {
            try {
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    NativeElementBridge.sendNativeEvent(event, json)
                } else {
                    NativeActionCoordinator.dispatchEvent(activity, event, json)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Could not dispatch $event", e)
            }
        }
    }
}
