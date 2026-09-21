# Changelog

All notable changes to `pteal79/image-annotator` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-21

### Added

- `ImageAnnotator::open()` presents a full-screen native annotation editor over a local image.
- Freehand, line, rectangle and text tools, with select, move, resize, restyle, layer order, delete, undo, redo, clear all and revert.
- Pinch-zoom and two-finger pan (up to 8x), one-finger pan on empty space in Select mode, and floating zoom out / fit / zoom in controls.
- `ImageAnnotationSaved`, `ImageAnnotationCancelled` and `ImageAnnotationFailed` events.
