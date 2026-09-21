import ImageIO
import UIKit

private typealias Editor = Pteal79Annotator.Editor
private typealias Renderer = Pteal79Annotator.Renderer
private typealias Session = Pteal79Annotator.Session
private typealias Tool = Pteal79Annotator.Tool
private typealias SizePreset = Pteal79Annotator.SizePreset
private typealias FontKey = Pteal79Annotator.FontKey
private typealias LayerMove = Pteal79Annotator.LayerMove
private typealias Palette = Pteal79Annotator.Palette
private typealias TextEditSession = Pteal79Annotator.TextEditSession

private enum Theme {
    static let background = UIColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255, alpha: 1)
    static let toolbar = UIColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x23 / 255, alpha: 1)
    static let control = UIColor(red: 0x3f / 255, green: 0x3f / 255, blue: 0x46 / 255, alpha: 1)
    static let text = UIColor(white: 0.9, alpha: 1)
    static let primary = UIColor(red: 0x25 / 255, green: 0x63 / 255, blue: 0xeb / 255, alpha: 1)
    static let danger = UIColor(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
    static let ring = UIColor(red: 0x52 / 255, green: 0x52 / 255, blue: 0x5b / 255, alpha: 1)
}

/// The full-screen editor. Presented by ImageAnnotatorFunctions.Open.
final class AnnotatorViewController: UIViewController, AnnotatorCanvasViewHost, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {

    private let request: Pteal79Annotator.Session.Request
    private let editor = Editor(measure: Renderer.measure)

    private let topBar = UIView()
    private let stage = UIView()
    private let bottomBar = UIView()
    private lazy var canvasView = AnnotatorCanvasView(editor: editor)
    private var saveButton: UIButton!

    private let contextScroll = UIScrollView()
    private let fillGroup = UIStackView()
    private var fillToggle: UIButton!
    private var fillSwatch: SwatchButton!
    private let layerGroup = UIStackView()
    private var layerButtons: [LayerMove: UIButton] = [:]
    private var colorSwatch: SwatchButton!
    private var sizeButtons: [SizePreset: UIButton] = [:]
    private let sizeDot = UIView()
    private var sizeDotWidth: NSLayoutConstraint!
    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var clearButton: UIButton!
    private var zoomOutButton: UIButton!
    private var zoomFitButton: UIButton!
    private var zoomInButton: UIButton!
    private var toolButtons: [Tool: UIButton] = [:]

    private var textView: AnnotatorTextView?
    private var formatBar: UIScrollView?
    private var formatContent: UIStackView?
    private var fontButton: UIButton?
    private var formatToggles: [String: UIButton] = [:]
    private var formatSizes: [SizePreset: UIButton] = [:]

    private var keyboardTop: CGFloat?
    private var isSaving = false
    private var isLoading = true
    private var hasAppeared = false
    private var failOnAppear = false
    /// Set once this controller has chosen its event, so dismissal does not also cancel.
    private var finishing = false

    init(request: Pteal79Annotator.Session.Request) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildUI()
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        loadImage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        hasAppeared = true
        if failOnAppear { failLoading() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Dismissed by something other than this controller: still end with one event.
        if !finishing && (isBeingDismissed || presentingViewController == nil) {
            finishing = true
            Session.cancelled(request)
        }
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        requestClose()
    }

    // MARK: Loading

    private func loadImage() {
        let path = request.imagePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeUpright(path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoading = false
                guard let image else {
                    if self.hasAppeared { self.failLoading() } else { self.failOnAppear = true }
                    return
                }
                self.canvasView.image = image
                self.refresh()
            }
        }
    }

    private func failLoading() {
        guard !finishing else { return }
        finishing = true
        let request = self.request
        dismiss(animated: true) {
            Session.failed(request, message: "Couldn't load the image.")
        }
    }

    /// Decodes the file with its EXIF orientation applied, at full size.
    static func decodeUpright(_ path: String) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    // MARK: UI

    private func buildUI() {
        for v in [stage, topBar, bottomBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        topBar.backgroundColor = Theme.toolbar
        bottomBar.backgroundColor = Theme.toolbar
        stage.backgroundColor = UIColor(red: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)

        canvasView.host = self
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(canvasView)

        let zoomControls = buildZoomControls()
        zoomControls.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(zoomControls)

        let close = makeButton(symbol: "xmark", label: "Close") { [weak self] in self?.requestClose() }
        close.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(close)

        var saveConfig = UIButton.Configuration.filled()
        saveConfig.title = "Save"
        saveConfig.baseBackgroundColor = Theme.primary
        saveConfig.baseForegroundColor = .white
        saveConfig.cornerStyle = .medium
        saveConfig.imagePadding = 6
        saveConfig.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18)
        saveConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = .systemFont(ofSize: 15, weight: .semibold)
            return a
        }
        saveButton = UIButton(configuration: saveConfig, primaryAction: UIAction { [weak self] _ in self?.save() })
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(saveButton)

        let rows = UIStackView(arrangedSubviews: [buildContextRow(), buildStyleRow(), buildToolsRow()])
        rows.axis = .vertical
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(rows)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: 52),

            close.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            close.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -4),
            close.heightAnchor.constraint(equalToConstant: 44),
            close.widthAnchor.constraint(equalToConstant: 44),

            saveButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            saveButton.centerYAnchor.constraint(equalTo: close.centerYAnchor),

            stage.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            canvasView.topAnchor.constraint(equalTo: stage.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            zoomControls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            zoomControls.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            rows.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),
            rows.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -6),
            rows.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4),
        ])
    }

    /// Floating zoom out / fit / zoom in buttons over the bottom-right of the canvas.
    private func buildZoomControls() -> UIView {
        let zoom: (@escaping () -> Void) -> () -> Void = { [weak self] action in
            {
                self?.commitTextIfEditing()
                action()
                self?.refresh()
            }
        }
        zoomOutButton = makeButton(symbol: "minus.magnifyingglass", label: "Zoom out",
                                   action: zoom { [weak self] in self?.canvasView.zoom(by: 1 / AnnotatorCanvasView.zoomStep) })
        zoomFitButton = makeButton(title: "Fit", label: "Fit image", action: zoom { [weak self] in self?.canvasView.resetZoom() })
        zoomInButton = makeButton(symbol: "plus.magnifyingglass", label: "Zoom in",
                                  action: zoom { [weak self] in self?.canvasView.zoom(by: AnnotatorCanvasView.zoomStep) })

        let row = UIStackView(arrangedSubviews: [zoomOutButton, zoomFitButton, zoomInButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 0
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        row.backgroundColor = Theme.toolbar.withAlphaComponent(0.9)
        row.layer.cornerRadius = 10
        row.layer.borderWidth = 1
        row.layer.borderColor = Theme.control.cgColor
        return row
    }

    private func buildContextRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4

        fillGroup.axis = .horizontal
        fillGroup.alignment = .center
        fillGroup.spacing = 6
        fillToggle = makeButton(symbol: "square.fill", title: "Fill") { [weak self] in
            guard let self else { return }
            self.editor.setFill(!self.editor.fill)
            self.refresh()
        }
        fillSwatch = SwatchButton(diameter: 26) { [weak self] swatch in
            guard let self else { return }
            self.showPalette(from: swatch, selected: self.editor.fillColor) { color in
                self.editor.setFillColor(color)
                self.refresh()
            }
        }
        fillSwatch.accessibilityLabel = "Fill colour"
        fillGroup.addArrangedSubview(fillToggle)
        fillGroup.addArrangedSubview(fillSwatch)
        fillGroup.addArrangedSubview(makeSeparator())
        row.addArrangedSubview(fillGroup)

        layerGroup.axis = .horizontal
        layerGroup.alignment = .center
        layerGroup.spacing = 2
        let layers: [(LayerMove, String, String)] = [
            (.front, "square.3.layers.3d.top.filled", "Bring to front"),
            (.forward, "square.2.layers.3d.top.filled", "Bring forward"),
            (.backward, "square.2.layers.3d.bottom.filled", "Send backward"),
            (.back, "square.3.layers.3d.bottom.filled", "Send to back"),
        ]
        for (move, symbol, label) in layers {
            let button = makeButton(symbol: symbol, label: label) { [weak self] in
                self?.editor.moveLayer(move)
                self?.refresh()
            }
            layerButtons[move] = button
            layerGroup.addArrangedSubview(button)
        }
        layerGroup.addArrangedSubview(makeSeparator())
        let delete = makeButton(symbol: "trash", title: "Delete", tint: Theme.danger) { [weak self] in
            self?.editor.deleteSelected()
            self?.refresh()
        }
        layerGroup.addArrangedSubview(delete)
        row.addArrangedSubview(layerGroup)

        return horizontalScroll(row, into: contextScroll)
    }

    private func buildStyleRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2

        colorSwatch = SwatchButton(diameter: 28) { [weak self] swatch in
            guard let self else { return }
            self.showPalette(from: swatch, selected: self.editor.color) { color in
                self.editor.setColor(color)
                self.applyTextStyle()
                self.refresh()
            }
        }
        colorSwatch.accessibilityLabel = "Colour"
        row.addArrangedSubview(colorSwatch)
        row.setCustomSpacing(8, after: colorSwatch)
        row.addArrangedSubview(makeSeparator())

        for preset in SizePreset.allCases {
            let button = makeButton(title: preset.label) { [weak self] in
                self?.editor.setSize(preset)
                self?.applyTextStyle()
                self?.refresh()
            }
            sizeButtons[preset] = button
            row.addArrangedSubview(button)
        }

        let dotBox = UIView()
        dotBox.translatesAutoresizingMaskIntoConstraints = false
        sizeDot.translatesAutoresizingMaskIntoConstraints = false
        dotBox.addSubview(sizeDot)
        sizeDotWidth = sizeDot.widthAnchor.constraint(equalToConstant: 4)
        NSLayoutConstraint.activate([
            dotBox.widthAnchor.constraint(equalToConstant: 26),
            dotBox.heightAnchor.constraint(equalToConstant: 26),
            sizeDot.centerXAnchor.constraint(equalTo: dotBox.centerXAnchor),
            sizeDot.centerYAnchor.constraint(equalTo: dotBox.centerYAnchor),
            sizeDotWidth,
            sizeDot.heightAnchor.constraint(equalTo: sizeDot.widthAnchor),
        ])
        row.addArrangedSubview(dotBox)
        row.addArrangedSubview(makeSeparator())

        undoButton = makeButton(symbol: "arrow.uturn.backward", label: "Undo") { [weak self] in
            self?.commitTextIfEditing()
            self?.editor.undo()
            self?.refresh()
        }
        redoButton = makeButton(symbol: "arrow.uturn.forward", label: "Redo") { [weak self] in
            self?.commitTextIfEditing()
            self?.editor.redo()
            self?.refresh()
        }
        clearButton = makeButton(symbol: "trash", label: "Clear all") { [weak self] in self?.confirmClearAll() }
        row.addArrangedSubview(undoButton)
        row.addArrangedSubview(redoButton)
        row.addArrangedSubview(clearButton)
        if request.originalPath != nil {
            row.addArrangedSubview(makeButton(symbol: "arrow.counterclockwise", label: "Revert") { [weak self] in self?.confirmRevert() })
        }

        return horizontalScroll(row, into: UIScrollView())
    }

    private func buildToolsRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4

        let tools: [(Tool, String, String)] = [
            (.select, "cursorarrow", "Select"),
            (.freehand, "scribble", "Pen"),
            (.line, "line.diagonal", "Line"),
            (.rect, "rectangle", "Rect"),
            (.text, "textformat", "Text"),
        ]
        for (tool, symbol, title) in tools {
            let button = makeButton(symbol: symbol, title: title, stacked: true) { [weak self] in
                self?.commitTextIfEditing()
                self?.editor.setTool(tool)
                self?.refresh()
            }
            toolButtons[tool] = button
            row.addArrangedSubview(button)
        }
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return row
    }

    private func horizontalScroll(_ content: UIStackView, into scroll: UIScrollView) -> UIScrollView {
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 44),
        ])
        return scroll
    }

    private func makeButton(symbol: String? = nil, title: String? = nil, label: String? = nil, tint: UIColor = Theme.text,
                            stacked: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        if let symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: stacked ? 17 : 16, weight: .medium))
        }
        config.imagePlacement = stacked ? .top : .leading
        config.imagePadding = stacked ? 3 : 5
        config.baseForegroundColor = tint
        config.background.cornerRadius = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = .systemFont(ofSize: stacked ? 11 : 14, weight: .medium)
            return a
        }

        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard self?.isSaving == false else { return }
            action()
        })
        button.accessibilityLabel = label ?? title
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.control
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22),
        ])
        return line
    }

    private func setSelected(_ button: UIButton?, _ selected: Bool, color: UIColor = Theme.control) {
        guard let button, var config = button.configuration else { return }
        config.background.backgroundColor = selected ? color : .clear
        if config.baseForegroundColor != Theme.danger {
            config.baseForegroundColor = selected ? .white : Theme.text
        }
        button.configuration = config
    }

    private func setEnabled(_ button: UIButton?, _ enabled: Bool) {
        button?.isEnabled = enabled
        button?.alpha = enabled ? 1 : 0.35
    }

    /// Brings every control in line with the editor state.
    private func refresh() {
        for (tool, button) in toolButtons { setSelected(button, editor.tool == tool, color: Theme.primary) }

        colorSwatch.hex = editor.color
        for (preset, button) in sizeButtons { setSelected(button, editor.size == preset) }
        sizeDot.backgroundColor = Renderer.color(editor.color)
        let dot = max(4, editor.size.stroke)
        sizeDotWidth.constant = dot
        sizeDot.layer.cornerRadius = dot / 2

        setEnabled(undoButton, editor.canUndo && !isSaving)
        setEnabled(redoButton, editor.canRedo && !isSaving)
        setEnabled(clearButton, !editor.shapes.isEmpty && !isSaving)

        let hasSelection = editor.selectedShape != nil && textView == nil
        fillGroup.isHidden = !editor.showsFillControls
        setSelected(fillToggle, editor.fill)
        fillSwatch.hex = editor.fillColor
        layerGroup.isHidden = !hasSelection
        setEnabled(layerButtons[.front], editor.canBringForward)
        setEnabled(layerButtons[.forward], editor.canBringForward)
        setEnabled(layerButtons[.backward], editor.canSendBackward)
        setEnabled(layerButtons[.back], editor.canSendBackward)
        contextScroll.isHidden = !(editor.showsFillControls || hasSelection)

        setEnabled(zoomOutButton, canvasView.canZoomOut)
        setEnabled(zoomFitButton, canvasView.canZoomOut)
        setEnabled(zoomInButton, canvasView.canZoomIn)
        if var config = zoomFitButton.configuration {
            config.title = canvasView.zoom > 1.001 ? "\(Int((canvasView.zoom * 100).rounded()))%" : "Fit"
            zoomFitButton.configuration = config
        }

        if var config = saveButton.configuration {
            config.title = isSaving ? "Saving\u{2026}" : "Save"
            config.showsActivityIndicator = isSaving
            saveButton.configuration = config
        }
        saveButton.isEnabled = !isSaving && canvasView.image != nil
        canvasView.isUserInteractionEnabled = !isSaving

        refreshFormatBar()
        canvasView.redraw()
    }

    // MARK: AnnotatorCanvasViewHost

    func canvasIsEditingText() -> Bool { textView != nil }

    func canvasCommitTextEditing() { commitTextEditing() }

    func canvasEditorChanged() {
        refresh()
        if textView != nil { positionTextUI() }
    }

    // MARK: Palette

    private func showPalette(from anchor: UIView, selected: String, onPick: @escaping (String) -> Void) {
        guard !isSaving else { return }

        let overlay = UIControl(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addAction(UIAction { [weak overlay] _ in overlay?.removeFromSuperview() }, for: .touchUpInside)

        let panel = UIStackView()
        panel.axis = .horizontal
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        panel.backgroundColor = UIColor(white: 0.165, alpha: 1)
        panel.layer.cornerRadius = 12
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.4
        panel.layer.shadowRadius = 8

        for hex in Palette.colors {
            let swatch = SwatchButton(diameter: 32) { [weak overlay] _ in
                overlay?.removeFromSuperview()
                onPick(hex)
            }
            swatch.hex = hex
            swatch.isChosen = hex.caseInsensitiveCompare(selected) == .orderedSame
            swatch.accessibilityLabel = hex
            panel.addArrangedSubview(swatch)
        }

        overlay.addSubview(panel)
        view.addSubview(overlay)

        let size = panel.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let anchorFrame = anchor.convert(anchor.bounds, to: view)
        let x = min(max(8, anchorFrame.midX - size.width / 2), max(8, view.bounds.width - size.width - 8))
        let y = max(view.safeAreaInsets.top + 8, anchorFrame.minY - size.height - 8)
        panel.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Text editing

    func canvasBeginTextEditing(_ session: Pteal79Annotator.TextEditSession) {
        removeTextUI()

        let textView = AnnotatorTextView()
        textView.delegate = self
        textView.text = session.initialText
        self.textView = textView
        stage.addSubview(textView)

        let bar = buildFormatBar(session)
        formatBar = bar
        stage.addSubview(bar)

        applyTextStyle()
        textView.becomeFirstResponder()
        refresh()
    }

    private func buildFormatBar(_ session: TextEditSession) -> UIScrollView {
        formatToggles = [:]
        formatSizes = [:]

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)

        var fontConfig = UIButton.Configuration.plain()
        fontConfig.baseForegroundColor = Theme.text
        fontConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        let fontButton = UIButton(configuration: fontConfig)
        fontButton.showsMenuAsPrimaryAction = true
        fontButton.menu = UIMenu(children: FontKey.allCases.map { key in
            UIAction(title: key.label) { [weak self] _ in
                self?.editor.textSession?.fontFamily = key
                self?.applyTextStyle()
            }
        })
        self.fontButton = fontButton
        row.addArrangedSubview(fontButton)

        for (key, symbol) in [("B", "bold"), ("I", "italic"), ("U", "underline")] {
            let button = makeButton(symbol: symbol, label: key == "B" ? "Bold" : key == "I" ? "Italic" : "Underline") { [weak self] in
                guard let session = self?.editor.textSession else { return }
                switch key {
                case "B": session.bold.toggle()
                case "I": session.italic.toggle()
                default: session.underline.toggle()
                }
                self?.applyTextStyle()
            }
            formatToggles[key] = button
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(makeSeparator())

        for preset in SizePreset.allCases {
            let button = makeButton(title: preset.label) { [weak self] in
                self?.editor.textSession?.size = preset
                self?.applyTextStyle()
            }
            formatSizes[preset] = button
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(makeSeparator())

        row.addArrangedSubview(makeButton(title: "Cancel") { [weak self] in self?.cancelTextEditing() })
        let done = makeButton(title: "Done", tint: .white) { [weak self] in self?.commitTextEditing() }
        if var config = done.configuration {
            config.background.backgroundColor = Theme.primary
            done.configuration = config
        }
        row.addArrangedSubview(done)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = Theme.toolbar
        scroll.layer.cornerRadius = 10
        scroll.layer.borderWidth = 1
        scroll.layer.borderColor = Theme.control.cgColor
        scroll.addSubview(row)
        formatContent = row
        return scroll
    }

    private func refreshFormatBar() {
        guard let session = editor.textSession else { return }
        if var config = fontButton?.configuration {
            config.title = session.fontFamily.label + " \u{25BE}"
            fontButton?.configuration = config
        }
        setSelected(formatToggles["B"], session.bold)
        setSelected(formatToggles["I"], session.italic)
        setSelected(formatToggles["U"], session.underline)
        for (preset, button) in formatSizes { setSelected(button, session.size == preset) }
    }

    /// Shows the field in its real font, style, colour and on-screen size.
    private func applyTextStyle() {
        guard let textView, let session = editor.textSession else { return }

        // The size the text will have on screen at the current zoom.
        let pointSize = session.fontSize(scale: editor.scale) / editor.touchScale
        let font = Pteal79Annotator.Fonts.font(session.fontFamily, size: pointSize, bold: session.bold, italic: session.italic)
        let color = Renderer.color(session.color)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if session.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        let selection = textView.selectedRange
        textView.attributedText = NSAttributedString(string: textView.text ?? "", attributes: attributes)
        textView.typingAttributes = attributes
        textView.selectedRange = selection
        textView.lineColor = color
        textView.placeholderFont = font
        textView.placeholderColor = color.withAlphaComponent(0.5)

        refreshFormatBar()
        positionTextUI()
    }

    func textViewDidChange(_ textView: UITextView) {
        (textView as? AnnotatorTextView)?.updatePlaceholder()
        positionTextUI()
    }

    /// Places the field at the text anchor and the format bar above it, or below near the top.
    private func positionTextUI() {
        guard let textView, let formatBar, let formatContent, let session = editor.textSession,
              stage.bounds.width > 0 else { return }

        let p = canvasView.convert(canvasView.toView(session.anchor), to: stage)
        let maxWidth = max(80, stage.bounds.width - p.x - 8)
        let font = textView.font ?? .systemFont(ofSize: session.size.font)
        let measured = (textView.text.isEmpty ? textView.placeholder : textView.text) as NSString
        let textWidth = measured.boundingRect(
            with: CGSize(width: maxWidth - 8, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font],
            context: nil
        ).width
        let width = min(maxWidth, max(80, ceil(textWidth) + 8))
        let height = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        textView.frame = CGRect(x: p.x, y: p.y, width: width, height: height)

        let content = formatContent.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        formatContent.frame = CGRect(origin: .zero, size: content)
        formatBar.contentSize = content
        let barWidth = min(content.width, stage.bounds.width - 16)
        let gap: CGFloat = 8
        let barTop = p.y - content.height - gap >= 0 ? p.y - content.height - gap : textView.frame.maxY + gap
        let barLeft = min(max(8, p.x), max(8, stage.bounds.width - barWidth - 8))
        formatBar.frame = CGRect(x: barLeft, y: barTop, width: barWidth, height: content.height)

        adjustForKeyboard()
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        keyboardTop = local.minY < view.bounds.height ? local.minY : nil
        animateAlongsideKeyboard(note) { self.adjustForKeyboard() }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardTop = nil
        animateAlongsideKeyboard(note) { self.adjustForKeyboard() }
    }

    private func animateAlongsideKeyboard(_ note: Notification, _ changes: @escaping () -> Void) {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState], animations: changes)
    }

    /// Moves the stage up when the keyboard would cover the field.
    private func adjustForKeyboard() {
        guard let textView, let keyboardTop else {
            stage.transform = .identity
            return
        }
        var bottom = textView.frame.maxY
        if let formatBar, formatBar.frame.minY > textView.frame.minY {
            bottom = formatBar.frame.maxY
        }
        let overlap = stage.frame.origin.y - stage.transform.ty + bottom + 12 - keyboardTop
        stage.transform = CGAffineTransform(translationX: 0, y: -max(0, overlap))
    }

    private func commitTextIfEditing() {
        if textView != nil { commitTextEditing() }
    }

    private func commitTextEditing() {
        guard let textView else { return }
        editor.commitText(textView.text ?? "")
        removeTextUI()
        refresh()
    }

    private func cancelTextEditing() {
        editor.cancelText()
        removeTextUI()
        refresh()
    }

    private func removeTextUI() {
        textView?.resignFirstResponder()
        textView?.removeFromSuperview()
        formatBar?.removeFromSuperview()
        textView = nil
        formatBar = nil
        formatContent = nil
        fontButton = nil
        formatToggles = [:]
        formatSizes = [:]
        stage.transform = .identity
    }

    // MARK: Dialogs

    private func confirm(_ title: String, _ message: String?, action: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }

    private func toast(_ message: String) {
        let label = PaddedLabel()
        label.text = message
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.alpha = 0
        view.addSubview(label)

        let size = label.intrinsicContentSize
        label.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: bottomBar.frame.minY - size.height - 16, width: size.width, height: size.height)

        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    private func requestClose() {
        guard !isSaving, !finishing else { return }
        commitTextIfEditing()
        if editor.hasUnsavedChanges {
            confirm("Discard changes?", nil, action: "Discard") { [weak self] in self?.cancel() }
        } else {
            cancel()
        }
    }

    private func cancel() {
        guard !finishing else { return }
        finishing = true
        let request = self.request
        dismiss(animated: true) {
            Session.cancelled(request)
        }
    }

    private func confirmClearAll() {
        commitTextIfEditing()
        guard !editor.shapes.isEmpty else { return }
        confirm(
            "Clear all annotations?",
            "This will remove every annotation from the image. This action can be undone.",
            action: "Clear all"
        ) { [weak self] in
            guard let self else { return }
            if self.editor.clearAll() { self.toast("Annotations cleared") }
            self.refresh()
        }
    }

    private func confirmRevert() {
        guard let originalPath = request.originalPath else { return }
        commitTextIfEditing()
        confirm(
            "Revert to original?",
            "This reloads the original, pre-annotation image and discards your current annotations. Save to keep the reverted image.",
            action: "Revert"
        ) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.decodeUpright(originalPath)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let image else {
                        self.toast("Couldn't load the original image")
                        return
                    }
                    self.removeTextUI()
                    self.editor.revert()
                    self.canvasView.image = image
                    self.toast("Reverted to original")
                    self.refresh()
                }
            }
        }
    }

    // MARK: Save

    private func save() {
        guard !isSaving, !isLoading, !finishing, let image = canvasView.image else { return }

        commitTextIfEditing()
        editor.prepareForSave()
        isSaving = true
        refresh()

        let shapes = editor.shapes
        let reverted = editor.reverted
        let request = self.request
        let name = "annotated-\(Self.safeFileId(request.id))-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var saved = false
            if let data = Renderer.export(image: image, shapes: shapes) {
                do {
                    try data.write(to: url, options: .atomic)
                    saved = true
                } catch {
                    NSLog("[pteal79/image-annotator] Could not write \(url.path): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSaving = false
                guard saved, let cgImage = image.cgImage else {
                    self.toast("Couldn't save image")
                    self.refresh()
                    return
                }
                self.finishing = true
                self.dismiss(animated: true) {
                    Session.saved(request, outputPath: url.path, width: cgImage.width, height: cgImage.height, reverted: reverted)
                }
            }
        }
    }

    static func safeFileId(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return safe.isEmpty ? "image" : safe
    }
}

/// A round colour swatch. White gets a thin dark ring so it stays visible.
private final class SwatchButton: UIControl {
    private let diameter: CGFloat
    private let onTap: (SwatchButton) -> Void

    var hex: String = Pteal79Annotator.Palette.defaultStroke {
        didSet { updateLook() }
    }

    var isChosen = false {
        didSet { updateLook() }
    }

    init(diameter: CGFloat, onTap: @escaping (SwatchButton) -> Void) {
        self.diameter = diameter
        self.onTap = onTap
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
        layer.cornerRadius = diameter / 2
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onTap(self)
        }, for: .touchUpInside)
        updateLook()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateLook() {
        backgroundColor = Pteal79Annotator.Renderer.color(hex)
        if isChosen {
            layer.borderWidth = 2.5
            layer.borderColor = Theme.primary.cgColor
        } else if hex.caseInsensitiveCompare(Pteal79Annotator.Palette.white) == .orderedSame {
            layer.borderWidth = 1.5
            layer.borderColor = Theme.ring.cgColor
        } else {
            layer.borderWidth = 1.5
            layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        }
    }
}

/// A transparent multi-line field with a dashed bottom border in the text colour.
private final class AnnotatorTextView: UITextView {
    let placeholder = "Type here\u{2026}"
    private let placeholderLabel = UILabel()
    private let dash = CAShapeLayer()

    var lineColor: UIColor = .white {
        didSet { dash.strokeColor = lineColor.cgColor }
    }

    var placeholderFont: UIFont? {
        didSet { placeholderLabel.font = placeholderFont }
    }

    var placeholderColor: UIColor? {
        didSet { placeholderLabel.textColor = placeholderColor }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        textContainer.lineFragmentPadding = 0
        autocapitalizationType = .sentences
        keyboardAppearance = .dark

        placeholderLabel.text = placeholder
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [4, 3]
        layer.addSublayer(dash)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
    }

    override var attributedText: NSAttributedString! {
        didSet { updatePlaceholder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.sizeToFit()
        placeholderLabel.frame.origin = .zero

        let y = bounds.height - dash.lineWidth / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: bounds.width, y: y))
        dash.path = path.cgPath
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
