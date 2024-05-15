//
//  CameraView.swift
//  ReactNativeCameraKit
//

import AVFoundation
import UIKit
import AVKit

/*
 * View abtracting the logic unrelated to the actual camera
 * Like permission, ratio overlay, focus, zoom gesture, write image, etc
 */
@objc(CKCameraView)
class CameraView: UIView {
    private let camera: CameraProtocol

    // Focus
    private let focusInterfaceView: FocusInterfaceView

    // scanner
    private var lastBarcodeDetectedTime: TimeInterval = 0
    private var scannerInterfaceView: ScannerInterfaceView
    private var supportedBarcodeType: [CodeFormat] = {
        return CodeFormat.allCases
    }()
    
    // camera
    private var ratioOverlayView: RatioOverlayView?

    // gestures
    private var zoomGestureRecognizer: UIPinchGestureRecognizer?

    // props
    // camera settings
    @objc var cameraType: CameraType = .back
    @objc var resizeMode: ResizeMode = .contain
    @objc var flashMode: FlashMode = .auto
    @objc var torchMode: TorchMode = .off
    // ratio overlay
    @objc var ratioOverlay: String?
    @objc var ratioOverlayColor: UIColor?
    // scanner
    @objc var scanBarcode = false
    @objc var showFrame = false
    @objc var onReadCode: RCTDirectEventBlock?
    @objc var scanThrottleDelay = 2000
    @objc var frameColor: UIColor?
    @objc var laserColor: UIColor?
    // other
    @objc var onOrientationChange: RCTDirectEventBlock?
    @objc var onZoom: RCTDirectEventBlock?
    @objc var resetFocusTimeout = 0
    @objc var resetFocusWhenMotionDetected = false
    @objc var focusMode: FocusMode = .on
    @objc var zoomMode: ZoomMode = .on
    @objc var zoom: NSNumber?
    @objc var maxZoom: NSNumber?

    @objc var onCaptureButtonPressIn: RCTDirectEventBlock?
    @objc var onCaptureButtonPressOut: RCTDirectEventBlock?
    
    var eventInteraction: Any? = nil

    // MARK: - Setup

    // This is used to delay camera setup until we have both granted permission & received default props
    var hasCameraBeenSetup = false
    var hasPropBeenSetup = false {
        didSet {
            setupCamera()
        }
    }
    var hasPermissionBeenGranted = false {
        didSet {
            setupCamera()
        }
    }
    private func setupCamera() {
        if hasPropBeenSetup && hasPermissionBeenGranted && !hasCameraBeenSetup {
            hasCameraBeenSetup = true
            camera.setup(cameraType: cameraType, supportedBarcodeType: scanBarcode && onReadCode != nil ? supportedBarcodeType : [])
        }
    }


    // MARK: Lifecycle

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(frame: CGRect) {
#if targetEnvironment(simulator)
        camera = SimulatorCamera()
#else
        camera = RealCamera()
#endif

        scannerInterfaceView = ScannerInterfaceView(frameColor: .white, laserColor: .red)
        focusInterfaceView = FocusInterfaceView()

        super.init(frame: frame)

        // Transfer the default values, otherwise the default wont take effect since it's a separate class
        focusInterfaceView.update(focusMode: focusMode)
        focusInterfaceView.update(resetFocusTimeout: resetFocusTimeout)
        focusInterfaceView.update(resetFocusWhenMotionDetected: resetFocusWhenMotionDetected)
        update(zoomMode: zoomMode)

        addSubview(camera.previewView)

        addSubview(scannerInterfaceView)
        scannerInterfaceView.isHidden = true

        addSubview(focusInterfaceView)
        focusInterfaceView.delegate = camera

        handleCameraPermission()
        
        configureHardwareInteraction()
    }
    
    private func configureHardwareInteraction() {
        // Create a new capture event interaction with a handler that captures a photo.
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                // Capture a photo on "press up" of a hardware button.
                if event.phase == .began {
                    self.onCaptureButtonPressIn?(nil)
                } else if event.phase == .ended {
                    self.onCaptureButtonPressOut?(nil)
                }
            }
            // Add the interaction to the view controller's view.
            self.addInteraction(interaction)
            eventInteraction = interaction
        }
    }
    


    override func removeFromSuperview() {
        camera.cameraRemovedFromSuperview()

        super.removeFromSuperview()
    }

    // MARK: React lifecycle

    override func reactSetFrame(_ frame: CGRect) {
        super.reactSetFrame(frame)

        camera.previewView.frame = bounds

        scannerInterfaceView.frame = bounds
        // If frame size changes, we have to update the scanner
        camera.update(scannerFrameSize: showFrame ? scannerInterfaceView.frameSize : nil)

        focusInterfaceView.frame = bounds

        ratioOverlayView?.frame = bounds
    }

    override func removeReactSubview(_ subview: UIView) {
        subview.removeFromSuperview()
        super.removeReactSubview(subview)
    }

    // Called once when all props have been set, then every time one is updated
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    override func didSetProps(_ changedProps: [String]) {
        hasPropBeenSetup = true

        // Camera settings
        if changedProps.contains("cameraType") {
            camera.update(cameraType: cameraType)
        }
        if changedProps.contains("flashMode") {
            camera.update(flashMode: flashMode)
        }
        if changedProps.contains("cameraType") || changedProps.contains("torchMode") {
            camera.update(torchMode: torchMode)
        }

        if changedProps.contains("onOrientationChange") {
            camera.update(onOrientationChange: onOrientationChange)
        }

        if changedProps.contains("onZoom") {
            camera.update(onZoom: onZoom)
        }
        
        if changedProps.contains("resizeMode") {
            camera.update(resizeMode: resizeMode)
        }

        // Ratio overlay
        if changedProps.contains("ratioOverlay") {
            if let ratioOverlay {
                if let ratioOverlayView {
                    ratioOverlayView.setRatio(ratioOverlay)
                } else {
                    ratioOverlayView = RatioOverlayView(frame: bounds, ratioString: ratioOverlay, overlayColor: ratioOverlayColor)
                    addSubview(ratioOverlayView!)
                }
            } else {
                ratioOverlayView?.removeFromSuperview()
                ratioOverlayView = nil
            }
        }

        if changedProps.contains("ratioOverlayColor"), let ratioOverlayColor {
            ratioOverlayView?.setColor(ratioOverlayColor)
        }

        // Scanner
        if changedProps.contains("scanBarcode") || changedProps.contains("onReadCode") {
            camera.isBarcodeScannerEnabled(scanBarcode,
                                           supportedBarcodeTypes: supportedBarcodeType,
                                           onBarcodeRead: { [weak self] (barcode, codeFormat) in
                                               self?.onBarcodeRead(barcode: barcode, codeFormat: codeFormat)
                                           })
        }



        if changedProps.contains("showFrame") || changedProps.contains("scanBarcode") {
            DispatchQueue.main.async {
                self.scannerInterfaceView.isHidden = !self.showFrame

                self.camera.update(scannerFrameSize: self.showFrame ? self.scannerInterfaceView.frameSize : nil)
            }
        }

        if changedProps.contains("laserColor"), let laserColor {
            scannerInterfaceView.update(laserColor: laserColor)
        }

        if changedProps.contains("frameColor"), let frameColor {
            scannerInterfaceView.update(frameColor: frameColor)
        }

        // Others
        if changedProps.contains("focusMode") {
            focusInterfaceView.update(focusMode: focusMode)
        }
        if changedProps.contains("resetFocusTimeout") {
            focusInterfaceView.update(resetFocusTimeout: resetFocusTimeout)
        }
        if changedProps.contains("resetFocusWhenMotionDetected") {
            focusInterfaceView.update(resetFocusWhenMotionDetected: resetFocusWhenMotionDetected)
        }

        if changedProps.contains("zoomMode") {
            self.update(zoomMode: zoomMode)
        }

        if changedProps.contains("zoom") {
            camera.update(zoom: zoom?.doubleValue)
        }

        if changedProps.contains("maxZoom") {
            camera.update(maxZoom: maxZoom?.doubleValue)
        }
    }

    // MARK: Public

    func capture(onSuccess: @escaping (_ imageObject: [String: Any]) -> Void,
                 onError: @escaping (_ error: String) -> Void) {
        camera.capturePicture(onWillCapture: { [weak self] in
            // Flash/dim preview to indicate shutter action
            DispatchQueue.main.async {
                self?.camera.previewView.alpha = 0
                UIView.animate(withDuration: 0.35, animations: {
                    self?.camera.previewView.alpha = 1
                })
            }
        }, onSuccess: { [weak self] imageData, thumbnailData, dimensions in
            DispatchQueue.global(qos: .default).async {
                self?.writeCaptured(imageData: imageData,
                                    thumbnailData: thumbnailData,
                                    dimensions: dimensions,
                                    onSuccess: onSuccess,
                                    onError: onError)

                self?.focusInterfaceView.resetFocus()
            }
        }, onError: onError)
    }

    // MARK: - Private Helper

    private func update(zoomMode: ZoomMode) {
        if zoomMode == .on {
            if zoomGestureRecognizer == nil {
                let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchToZoomRecognizer(_:)))
                addGestureRecognizer(pinchGesture)
                zoomGestureRecognizer = pinchGesture
            }
        } else {
            if let zoomGestureRecognizer {
                removeGestureRecognizer(zoomGestureRecognizer)
                self.zoomGestureRecognizer = nil
            }
        }
    }

    private func handleCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            hasPermissionBeenGranted = true
        case .notDetermined:
            // The user has not yet been presented with the option to grant video access.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.hasPermissionBeenGranted = true
                }
            }
        default:
            // The user has previously denied access.
            break
        }
    }

    private func writeCaptured(imageData: Data,
                               thumbnailData: Data?,
                               dimensions: CMVideoDimensions,
                               onSuccess: @escaping (_ imageObject: [String: Any]) -> Void,
                               onError: @escaping (_ error: String) -> Void) {
        do {
            let temporaryImageFileURL = try saveToTmpFolder(imageData)

            onSuccess([
                "size": imageData.count,
                "uri": temporaryImageFileURL.description,
                "name": temporaryImageFileURL.lastPathComponent,
                "thumb": "",
                "height": dimensions.height,
                "width": dimensions.width
            ])
        } catch {
            let errorMessage = "Error occurred while writing image data to a temporary file: \(error)"
            print(errorMessage)
            onError(errorMessage)
        }
    }

    private func saveToTmpFolder(_ data: Data) throws -> URL {
        let temporaryFileName = ProcessInfo.processInfo.globallyUniqueString
        // Store temporary photos in the 'caches' directory to support expo-file-system
        let cachesUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var temporaryFolderURL = cachesUrl
        if let bundleId = Bundle.main.bundleIdentifier {
            temporaryFolderURL = temporaryFolderURL.appendingPathComponent(bundleId, isDirectory: true)
        }
        temporaryFolderURL = temporaryFolderURL.appendingPathComponent("com.tesla.react-native-camera-kit", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true)
        let temporaryFileURL = temporaryFolderURL.appendingPathComponent("\(temporaryFileName).jpg")

        try data.write(to: temporaryFileURL, options: .atomic)

        return temporaryFileURL
    }

    private func onBarcodeRead(barcode: String, codeFormat:CodeFormat) {
        // Throttle barcode detection
        let now = Date.timeIntervalSinceReferenceDate
        guard lastBarcodeDetectedTime + Double(scanThrottleDelay) / 1000 < now else {
            return
        }

        lastBarcodeDetectedTime = now

        onReadCode?(["codeStringValue": barcode,"codeFormat":codeFormat.rawValue])
    }

    // MARK: - Gesture selectors

    @objc func handlePinchToZoomRecognizer(_ pinchRecognizer: UIPinchGestureRecognizer) {
        if pinchRecognizer.state == .began {
            camera.zoomPinchStart()
        }
        if pinchRecognizer.state == .changed {
            camera.zoomPinchChange(pinchScale: pinchRecognizer.scale)
        }
    }
}
