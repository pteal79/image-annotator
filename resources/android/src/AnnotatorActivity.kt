package com.pteal79.plugins.imageannotator

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.ExifInterface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.PopupWindow
import android.widget.TextView
import android.widget.Toast
import androidx.activity.addCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.AppCompatEditText
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The full-screen editor. Started by ImageAnnotatorFunctions.Open. */
class AnnotatorActivity : AppCompatActivity(), AnnotatorCanvasView.Host {

    private object Colors {
        val BACKGROUND = Color.parseColor("#1a1a1a")
        val TOOLBAR = Color.parseColor("#232323")
        val CONTROL = Color.parseColor("#3f3f46")
        val TEXT = Color.parseColor("#e5e5e5")
        val PRIMARY = Color.parseColor("#2563eb")
        val DANGER = Color.parseColor("#ef4444")
        val RING = Color.parseColor("#52525b")
    }

    private lateinit var request: AnnotatorSession.Request
    private lateinit var state: AnnotatorSession.State
    private val editor get() = state.editor

    private val main = Handler(Looper.getMainLooper())
    private val density by lazy { resources.displayMetrics.density }

    private lateinit var root: LinearLayout
    private lateinit var topBar: FrameLayout
    private lateinit var stage: FrameLayout
    private lateinit var canvasView: AnnotatorCanvasView
    private lateinit var saveButton: TextView

    private lateinit var contextScroll: HorizontalScrollView
    private lateinit var fillGroup: LinearLayout
    private lateinit var fillToggle: TextView
    private lateinit var fillSwatch: View
    private lateinit var layerGroup: LinearLayout
    private val layerButtons = LinkedHashMap<LayerMove, TextView>()
    private lateinit var colorSwatch: View
    private lateinit var sizeDot: View
    private val sizeButtons = LinkedHashMap<SizePreset, TextView>()
    private lateinit var undoButton: TextView
    private lateinit var redoButton: TextView
    private lateinit var clearButton: TextView
    private lateinit var zoomOutButton: TextView
    private lateinit var zoomFitButton: TextView
    private lateinit var zoomInButton: TextView
    private val toolButtons = LinkedHashMap<Tool, TextView>()

    private var textField: AnnotatorTextField? = null
    private var formatScroll: HorizontalScrollView? = null
    private var fontButton: TextView? = null
    private val formatToggles = LinkedHashMap<String, TextView>()
    private val formatSizes = LinkedHashMap<SizePreset, TextView>()

    private var imeBottom = 0
    private var isSaving = false
    private var isLoading = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val current = AnnotatorSession.request
        if (current == null) {
            finish()
            return
        }
        request = current

        state = AnnotatorSession.state ?: AnnotatorRenderer().let { renderer ->
            AnnotatorSession.State(AnnotatorEditor(renderer), renderer).also { AnnotatorSession.state = it }
        }

        WindowCompat.setDecorFitsSystemWindows(window, false)
        @Suppress("DEPRECATION")
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)

        buildUi()
        WindowCompat.getInsetsController(window, root).isAppearanceLightStatusBars = false

        onBackPressedDispatcher.addCallback(this) {
            if (textField != null) cancelTextEditing() else requestClose()
        }

        val image = state.image
        if (image != null) {
            canvasView.image = image
        } else {
            loadImage()
        }
        refresh()
    }

    override fun onDestroy() {
        super.onDestroy()
        main.removeCallbacksAndMessages(null)
        // Leaving any other way (the task was removed) still ends with one event.
        if (isFinishing && ::request.isInitialized) {
            AnnotatorSession.cancelled(request)
        }
    }

    // Loading

    private fun loadImage() {
        isLoading = true
        Thread {
            val bitmap = decodeUpright(request.imagePath)
            main.post {
                isLoading = false
                if (isDestroyed) return@post
                if (bitmap == null) {
                    finish()
                    AnnotatorSession.failed(request, "Couldn't load the image.")
                    return@post
                }
                state.image = bitmap
                canvasView.image = bitmap
                refresh()
            }
        }.start()
    }

    // UI

    private fun dp(value: Float): Int = (value * density).roundToInt()

    private fun buildUi() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Colors.BACKGROUND)
        }

        topBar = FrameLayout(this).apply {
            setBackgroundColor(Colors.TOOLBAR)
            translationZ = dp(4f).toFloat()
        }
        val close = TextView(this).apply {
            text = "✕"
            setTextColor(Colors.TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            gravity = Gravity.CENTER
            contentDescription = "Close"
            setOnClickListener { requestClose() }
        }
        topBar.addView(close, FrameLayout.LayoutParams(dp(52f), dp(52f), Gravity.START or Gravity.CENTER_VERTICAL))
        saveButton = TextView(this).apply {
            text = "Save"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(18f), 0, dp(18f), 0)
            background = rounded(Colors.PRIMARY, 8f)
            setOnClickListener { save() }
        }
        topBar.addView(
            saveButton,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36f), Gravity.END or Gravity.CENTER_VERTICAL).apply { marginEnd = dp(10f) }
        )
        root.addView(topBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52f)))

        stage = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#0f0f0f")) }
        canvasView = AnnotatorCanvasView(this, editor, state.renderer).also { it.host = this }
        stage.addView(canvasView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        stage.addView(
            buildZoomControls(),
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.END or Gravity.BOTTOM)
                .apply { setMargins(0, 0, dp(10f), dp(10f)) }
        )
        root.addView(stage, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Colors.TOOLBAR)
            setPadding(dp(6f), dp(4f), dp(6f), dp(6f))
            translationZ = dp(4f).toFloat()
        }
        bottom.addView(buildContextRow())
        bottom.addView(buildStyleRow())
        bottom.addView(buildToolsRow())
        root.addView(bottom, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            main.post { adjustForKeyboard() }
            insets
        }

        setContentView(root)
    }

    /** Floating zoom out / fit / zoom in buttons over the bottom-right of the canvas. */
    private fun buildZoomControls(): View {
        val zoom: (() -> Unit) -> Unit = { action ->
            if (textField != null) commitTextEditing()
            action()
            refresh()
        }
        zoomOutButton = pill("\u2212") { zoom { canvasView.zoomBy(1f / AnnotatorCanvasView.ZOOM_STEP) } }
            .apply { contentDescription = "Zoom out" }
        zoomFitButton = pill("Fit") { zoom { canvasView.resetZoom() } }
            .apply { contentDescription = "Fit image" }
        zoomInButton = pill("+") { zoom { canvasView.zoomBy(AnnotatorCanvasView.ZOOM_STEP) } }
            .apply { contentDescription = "Zoom in" }

        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(Color.parseColor("#e6232323"), 10f).apply { setStroke(dp(1f), Colors.CONTROL) }
            elevation = dp(4f).toFloat()
            setPadding(dp(2f), 0, dp(2f), 0)
            addView(zoomOutButton)
            addView(zoomFitButton)
            addView(zoomInButton)
        }
    }

    private fun buildContextRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        fillGroup = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        fillToggle = pill("Fill") { editor.setFill(!editor.fill); refresh() }
        fillGroup.addView(fillToggle)
        fillSwatch = swatch(Palette.DEFAULT_FILL, 26f).apply {
            contentDescription = "Fill colour"
            setOnClickListener { showPalette(this, editor.fillColor) { editor.setFillColor(it); refresh() } }
        }
        fillGroup.addView(fillSwatch, marginParams(26f, 26f, 6f))
        fillGroup.addView(separator())
        row.addView(fillGroup)

        layerGroup = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        listOf(
            LayerMove.FRONT to "⤒ Front",
            LayerMove.FORWARD to "↑ Forward",
            LayerMove.BACKWARD to "↓ Backward",
            LayerMove.BACK to "⤓ Back",
        ).forEach { (move, label) ->
            val button = pill(label) { editor.moveLayer(move); refresh() }
            layerButtons[move] = button
            layerGroup.addView(button)
        }
        layerGroup.addView(separator())
        layerGroup.addView(pill("Delete", Colors.DANGER) { editor.deleteSelected(); refresh() })
        row.addView(layerGroup)

        contextScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
        return contextScroll
    }

    private fun buildStyleRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        colorSwatch = swatch(Palette.DEFAULT_STROKE, 28f).apply {
            contentDescription = "Colour"
            setOnClickListener { showPalette(this, editor.color) { editor.setColor(it); applyTextStyle(); refresh() } }
        }
        row.addView(colorSwatch, marginParams(28f, 28f, 6f))
        row.addView(separator())

        SizePreset.values().forEach { preset ->
            val button = pill(preset.label) { editor.setSize(preset); applyTextStyle(); refresh() }
            sizeButtons[preset] = button
            row.addView(button)
        }
        sizeDot = View(this)
        row.addView(sizeDot, marginParams(16f, 16f, 6f))
        row.addView(separator())

        undoButton = pill("↶") {
            if (textField != null) commitTextEditing()
            editor.undo()
            refresh()
        }.apply { contentDescription = "Undo" }
        redoButton = pill("↷") {
            if (textField != null) commitTextEditing()
            editor.redo()
            refresh()
        }.apply { contentDescription = "Redo" }
        clearButton = pill("Clear") { confirmClearAll() }.apply { contentDescription = "Clear all" }
        row.addView(undoButton)
        row.addView(redoButton)
        row.addView(clearButton)
        if (request.originalPath != null) {
            row.addView(pill("⟲ Revert") { confirmRevert() }.apply { contentDescription = "Revert" })
        }

        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
    }

    private fun buildToolsRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        listOf(
            Tool.SELECT to "Select",
            Tool.FREEHAND to "Pen",
            Tool.LINE to "Line",
            Tool.RECT to "Rect",
            Tool.TEXT to "Text",
        ).forEach { (tool, label) ->
            val button = pill(label) {
                if (textField != null) commitTextEditing()
                editor.setTool(tool)
                refresh()
            }
            toolButtons[tool] = button
            row.addView(button, LinearLayout.LayoutParams(0, dp(40f), 1f).apply { setMargins(dp(2f), dp(2f), dp(2f), 0) })
        }
        return row
    }

    private fun pill(label: String, textColor: Int = Colors.TEXT, onClick: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            minWidth = dp(36f)
            setPadding(dp(10f), 0, dp(10f), 0)
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36f)).apply {
                setMargins(dp(2f), dp(3f), dp(2f), dp(3f))
            }
            background = rounded(Color.TRANSPARENT, 8f)
            setOnClickListener { if (!isSaving) onClick() }
        }

    private fun swatch(hex: String, sizeDp: Float): View = View(this).apply {
        background = circle(hex, sizeDp)
    }

    private fun circle(hex: String, sizeDp: Float, selected: Boolean = false): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(AnnotatorRenderer.parseColor(hex))
            setSize(dp(sizeDp), dp(sizeDp))
            when {
                selected -> setStroke(dp(2.5f), Colors.PRIMARY)
                hex.equals(Palette.WHITE, ignoreCase = true) -> setStroke(dp(1.5f), Colors.RING)
                else -> setStroke(dp(1.5f), Color.parseColor("#33ffffff"))
            }
        }

    private fun rounded(color: Int, radiusDp: Float): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun separator(): View = View(this).apply {
        setBackgroundColor(Colors.CONTROL)
        layoutParams = LinearLayout.LayoutParams(dp(1f), dp(22f)).apply { setMargins(dp(6f), 0, dp(6f), 0) }
    }

    private fun marginParams(w: Float, h: Float, margin: Float) =
        LinearLayout.LayoutParams(dp(w), dp(h)).apply { setMargins(dp(margin), 0, dp(margin), 0) }

    private fun setSelected(view: TextView, selected: Boolean, selectedColor: Int = Colors.CONTROL) {
        view.background = rounded(if (selected) selectedColor else Color.TRANSPARENT, 8f)
        if (view.currentTextColor != Colors.DANGER) {
            view.setTextColor(if (selected) Color.WHITE else Colors.TEXT)
        }
    }

    private fun setEnabled(view: View, enabled: Boolean) {
        view.isEnabled = enabled
        view.alpha = if (enabled) 1f else 0.35f
    }

    /** Brings every control in line with the editor state. */
    private fun refresh() {
        toolButtons.forEach { (tool, button) -> setSelected(button, editor.tool == tool, Colors.PRIMARY) }

        colorSwatch.background = circle(editor.color, 28f)
        sizeButtons.forEach { (preset, button) -> setSelected(button, editor.size == preset) }
        val dot = max(4f, editor.size.stroke)
        sizeDot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(AnnotatorRenderer.parseColor(editor.color))
            setSize(dp(dot), dp(dot))
        }
        sizeDot.layoutParams = (sizeDot.layoutParams as LinearLayout.LayoutParams).apply {
            width = dp(dot)
            height = dp(dot)
        }

        setEnabled(undoButton, editor.canUndo && !isSaving)
        setEnabled(redoButton, editor.canRedo && !isSaving)
        setEnabled(clearButton, editor.shapes.isNotEmpty() && !isSaving)

        val hasSelection = editor.selectedShape != null && textField == null
        fillGroup.visibility = if (editor.showsFillControls) View.VISIBLE else View.GONE
        setSelected(fillToggle, editor.fill)
        fillSwatch.background = circle(editor.fillColor, 26f)
        layerGroup.visibility = if (hasSelection) View.VISIBLE else View.GONE
        setEnabled(layerButtons.getValue(LayerMove.FRONT), editor.canBringForward)
        setEnabled(layerButtons.getValue(LayerMove.FORWARD), editor.canBringForward)
        setEnabled(layerButtons.getValue(LayerMove.BACKWARD), editor.canSendBackward)
        setEnabled(layerButtons.getValue(LayerMove.BACK), editor.canSendBackward)
        contextScroll.visibility = if (editor.showsFillControls || hasSelection) View.VISIBLE else View.GONE

        setEnabled(zoomOutButton, canvasView.canZoomOut)
        setEnabled(zoomFitButton, canvasView.canZoomOut)
        setEnabled(zoomInButton, canvasView.canZoomIn)
        zoomFitButton.text = if (canvasView.zoom > 1.001f) "${(canvasView.zoom * 100).roundToInt()}%" else "Fit"

        saveButton.text = if (isSaving) "Saving…" else "Save"
        saveButton.alpha = if (isSaving || canvasView.image == null) 0.6f else 1f
        canvasView.isEnabled = !isSaving

        refreshFormatBar()
        canvasView.invalidate()
    }

    override fun onEditorChanged() {
        refresh()
        if (textField != null) positionTextUi()
    }

    // Palette

    private fun showPalette(anchor: View, selected: String, onPick: (String) -> Unit) {
        if (isSaving) return
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(8f), dp(8f), dp(8f), dp(8f))
            background = rounded(Color.parseColor("#2a2a2a"), 12f)
        }
        val popup = PopupWindow(row, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
            elevation = dp(8f).toFloat()
        }
        Palette.colors.forEach { hex ->
            row.addView(View(this).apply {
                background = circle(hex, 32f, hex.equals(selected, ignoreCase = true))
                contentDescription = hex
                setOnClickListener {
                    popup.dismiss()
                    onPick(hex)
                }
            }, marginParams(32f, 32f, 4f))
        }

        row.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        val location = IntArray(2)
        anchor.getLocationInWindow(location)
        val x = (location[0] + anchor.width / 2 - row.measuredWidth / 2)
            .coerceIn(dp(8f), max(dp(8f), root.width - row.measuredWidth - dp(8f)))
        val y = max(dp(8f), location[1] - row.measuredHeight - dp(8f))
        popup.showAtLocation(anchor, Gravity.NO_GRAVITY, x, y)
    }

    // Text editing

    override fun isEditingText(): Boolean = textField != null

    override fun beginTextEditing(session: TextEditSession) {
        removeTextUi()

        val field = AnnotatorTextField(this).apply {
            setText(session.initialText)
            setSelection(text?.length ?: 0)
        }
        textField = field
        stage.addView(field, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val bar = buildFormatBar(session)
        formatScroll = bar
        stage.addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        applyTextStyle()
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                field.post { positionTextUi() }
            }
        })
        field.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            positionTextUi()
            adjustForKeyboard()
        }
        bar.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> positionTextUi() }

        positionTextUi()
        field.post {
            field.requestFocus()
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
        }
        refresh()
    }

    private fun buildFormatBar(session: TextEditSession): HorizontalScrollView {
        formatToggles.clear()
        formatSizes.clear()

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4f), 0, dp(4f), 0)
        }

        fontButton = pill(session.fontFamily.label + " ▾") {
            val menu = PopupMenu(this, fontButton!!)
            FontKey.values().forEachIndexed { i, key -> menu.menu.add(0, i, i, key.label) }
            menu.setOnMenuItemClickListener { item ->
                session.fontFamily = FontKey.values()[item.itemId]
                applyTextStyle()
                true
            }
            menu.show()
        }
        row.addView(fontButton)

        listOf("B", "I", "U").forEach { key ->
            val button = pill(key) {
                when (key) {
                    "B" -> session.bold = !session.bold
                    "I" -> session.italic = !session.italic
                    else -> session.underline = !session.underline
                }
                applyTextStyle()
            }
            when (key) {
                "B" -> button.typeface = Typeface.DEFAULT_BOLD
                "I" -> button.setTypeface(null, Typeface.ITALIC)
                else -> button.paintFlags = button.paintFlags or Paint.UNDERLINE_TEXT_FLAG
            }
            formatToggles[key] = button
            row.addView(button)
        }
        row.addView(separator())

        SizePreset.values().forEach { preset ->
            val button = pill(preset.label) {
                session.size = preset
                applyTextStyle()
            }
            formatSizes[preset] = button
            row.addView(button)
        }
        row.addView(separator())

        row.addView(pill("Cancel") { cancelTextEditing() })
        row.addView(pill("Done", Color.WHITE) { commitTextEditing() }.apply { background = rounded(Colors.PRIMARY, 8f) })

        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            background = rounded(Colors.TOOLBAR, 10f).apply { setStroke(dp(1f), Colors.CONTROL) }
            elevation = dp(6f).toFloat()
            addView(row)
        }
    }

    private fun refreshFormatBar() {
        val session = editor.textSession ?: return
        fontButton?.text = session.fontFamily.label + " ▾"
        formatToggles["B"]?.let { setSelected(it, session.bold) }
        formatToggles["I"]?.let { setSelected(it, session.italic) }
        formatToggles["U"]?.let { setSelected(it, session.underline) }
        formatSizes.forEach { (preset, button) -> setSelected(button, session.size == preset) }
    }

    /** Shows the field in its real font, style, colour and on-screen size. */
    private fun applyTextStyle() {
        val field = textField ?: return
        val session = editor.textSession ?: return

        val face = Fonts.typeface(session.fontFamily, session.bold, session.italic)
        field.typeface = face
        field.paint.isFakeBoldText = session.bold && !face.isBold
        field.paint.textSkewX = if (session.italic && !face.isItalic) -0.25f else 0f
        field.paintFlags = if (session.underline) {
            field.paintFlags or Paint.UNDERLINE_TEXT_FLAG
        } else {
            field.paintFlags and Paint.UNDERLINE_TEXT_FLAG.inv()
        }
        // The size the text will have on screen at the current zoom.
        field.setTextSize(TypedValue.COMPLEX_UNIT_DIP, session.fontSize(editor.scale) / editor.touchScale)
        val color = AnnotatorRenderer.parseColor(session.color)
        field.setTextColor(color)
        field.setHintTextColor((color and 0x00ffffff) or 0x80000000.toInt())
        field.lineColor = color
        field.invalidate()

        refreshFormatBar()
        field.post { positionTextUi() }
    }

    /** Places the field at the text anchor and the format bar above it, or below near the top. */
    private fun positionTextUi() {
        val field = textField ?: return
        val bar = formatScroll ?: return
        val session = editor.textSession ?: return
        if (stage.width == 0) return

        val p = canvasView.toView(session.anchor)
        val left = p.x.roundToInt()
        val top = p.y.roundToInt()
        val maxWidth = max(dp(80f), stage.width - left - dp(8f))

        val fieldParams = field.layoutParams as FrameLayout.LayoutParams
        if (fieldParams.leftMargin != left || fieldParams.topMargin != top || field.maxWidth != maxWidth) {
            field.maxWidth = maxWidth
            fieldParams.leftMargin = left
            fieldParams.topMargin = top
            field.layoutParams = fieldParams
        }

        val barParams = bar.layoutParams as FrameLayout.LayoutParams
        val content = bar.getChildAt(0)
        content.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        val barWidth = min(content.measuredWidth, stage.width - dp(16f))
        val barHeight = content.measuredHeight
        val gap = dp(8f)
        val barTop = if (top - barHeight - gap >= 0) top - barHeight - gap else top + max(field.height, dp(40f)) + gap
        val barLeft = left.coerceIn(dp(8f), max(dp(8f), stage.width - barWidth - dp(8f)))
        if (barParams.leftMargin != barLeft || barParams.topMargin != barTop || barParams.width != barWidth) {
            barParams.leftMargin = barLeft
            barParams.topMargin = barTop
            barParams.width = barWidth
            bar.layoutParams = barParams
        }
    }

    /** Moves the stage up when the keyboard would cover the field. */
    private fun adjustForKeyboard() {
        val field = textField
        if (field == null || imeBottom == 0 || !::stage.isInitialized) {
            if (::stage.isInitialized) stage.translationY = 0f
            return
        }

        val fieldParams = field.layoutParams as FrameLayout.LayoutParams
        var bottom = fieldParams.topMargin + field.height
        formatScroll?.let { bar ->
            val barParams = bar.layoutParams as FrameLayout.LayoutParams
            if (barParams.topMargin > fieldParams.topMargin) bottom = barParams.topMargin + bar.height
        }

        val keyboardTop = root.height - imeBottom
        val overlap = stage.top + bottom + dp(12f) - keyboardTop
        stage.translationY = -max(0, overlap).toFloat()
    }

    override fun commitTextEditing() {
        val field = textField ?: return
        editor.commitText(field.text?.toString().orEmpty())
        removeTextUi()
        refresh()
    }

    private fun cancelTextEditing() {
        editor.cancelText()
        removeTextUi()
        refresh()
    }

    private fun removeTextUi() {
        textField?.let { field ->
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(field.windowToken, 0)
            stage.removeView(field)
        }
        formatScroll?.let { stage.removeView(it) }
        textField = null
        formatScroll = null
        fontButton = null
        formatToggles.clear()
        formatSizes.clear()
        stage.translationY = 0f
    }

    // Dialogs

    private fun confirm(title: String, message: String?, action: String, onConfirm: () -> Unit) {
        val dialog = AlertDialog.Builder(this)
            .setTitle(title)
            .apply { if (message != null) setMessage(message) }
            .setNegativeButton("Cancel", null)
            .setPositiveButton(action) { _, _ -> onConfirm() }
            .show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(Colors.DANGER)
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun requestClose() {
        if (isSaving) return
        if (textField != null) commitTextEditing()
        if (editor.hasUnsavedChanges) {
            confirm("Discard changes?", null, "Discard") { cancel() }
        } else {
            cancel()
        }
    }

    private fun cancel() {
        finish()
        AnnotatorSession.cancelled(request)
    }

    private fun confirmClearAll() {
        if (textField != null) commitTextEditing()
        if (editor.shapes.isEmpty()) return
        confirm(
            "Clear all annotations?",
            "This will remove every annotation from the image. This action can be undone.",
            "Clear all",
        ) {
            if (editor.clearAll()) toast("Annotations cleared")
            refresh()
        }
    }

    private fun confirmRevert() {
        val originalPath = request.originalPath ?: return
        if (textField != null) commitTextEditing()
        confirm(
            "Revert to original?",
            "This reloads the original, pre-annotation image and discards your current annotations. Save to keep the reverted image.",
            "Revert",
        ) {
            Thread {
                val bitmap = decodeUpright(originalPath)
                main.post {
                    if (isDestroyed) return@post
                    if (bitmap == null) {
                        toast("Couldn't load the original image")
                        return@post
                    }
                    removeTextUi()
                    editor.revert()
                    state.image = bitmap
                    canvasView.image = bitmap
                    toast("Reverted to original")
                    refresh()
                }
            }.start()
        }
    }

    // Save

    private fun save() {
        if (isSaving || isLoading) return
        val image = canvasView.image ?: return

        if (textField != null) commitTextEditing()
        editor.prepareForSave()
        isSaving = true
        refresh()

        val shapes = editor.shapes
        val reverted = editor.reverted
        val name = "annotated-${safeFileId(request.id)}-${System.currentTimeMillis()}.jpg"
        val file = File(cacheDir, name)

        Thread {
            val saved = try {
                export(image, shapes, file)
                true
            } catch (e: Throwable) {
                Log.e(TAG, "Could not save the annotated image", e)
                file.delete()
                false
            }

            main.post {
                if (isDestroyed) return@post
                isSaving = false
                if (saved) {
                    finish()
                    AnnotatorSession.saved(request, file.absolutePath, image.width, image.height, reverted)
                } else {
                    toast("Couldn't save image")
                    refresh()
                }
            }
        }.start()
    }

    companion object {
        private const val TAG = "Pteal79ImageAnnotator"
        private const val JPEG_QUALITY = 92

        /** Renders the image and shapes at full resolution with the on-screen code, without the overlay. */
        fun export(image: Bitmap, shapes: List<Shape>, file: File) {
            val output = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(output)
                canvas.drawColor(Color.WHITE)
                canvas.drawBitmap(image, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
                val renderer = AnnotatorRenderer()
                shapes.forEach { renderer.draw(canvas, it) }

                FileOutputStream(file).use { stream ->
                    if (!output.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, stream)) {
                        throw IOException("JPEG encoding failed")
                    }
                }
            } finally {
                output.recycle()
            }
        }

        fun safeFileId(id: String): String = id.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "image" }

        /** Decodes the file and applies its EXIF orientation so it is upright. */
        fun decodeUpright(path: String): Bitmap? {
            return try {
                val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
                val raw = BitmapFactory.decodeFile(path, options) ?: return null

                val orientation = try {
                    ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                } catch (e: IOException) {
                    ExifInterface.ORIENTATION_NORMAL
                }

                val matrix = Matrix()
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        matrix.setRotate(90f)
                        matrix.postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> {
                        matrix.setRotate(-90f)
                        matrix.postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
                    else -> return raw
                }

                val upright = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
                if (upright != raw) raw.recycle()
                upright
            } catch (e: Throwable) {
                Log.e(TAG, "Could not decode $path", e)
                null
            }
        }
    }
}

/** A transparent multi-line field with a dashed bottom border in the text colour. */
class AnnotatorTextField(context: Context) : AppCompatEditText(context) {
    private val density = resources.displayMetrics.density

    var lineColor: Int = Color.WHITE
        set(value) {
            field = value
            dashPaint.color = value
        }

    private val dashPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        pathEffect = DashPathEffect(floatArrayOf(4f * density, 3f * density), 0f)
    }

    init {
        background = null
        includeFontPadding = false
        setPadding(0, 0, 0, (6 * density).toInt())
        gravity = Gravity.TOP or Gravity.START
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        isSingleLine = false
        setHorizontallyScrolling(false)
        minWidth = (80 * density).toInt()
        hint = "Type here…"
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val y = scrollY + height - dashPaint.strokeWidth
        canvas.drawLine(scrollX.toFloat(), y, (scrollX + width).toFloat(), y, dashPaint)
    }
}
