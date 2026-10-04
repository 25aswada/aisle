import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// The camera as a pop-up card that rises over the chat, which stays visible and dimmed
/// above it: a live preview you can pinch to zoom, zoom presets, and back, shutter and
/// photo-library buttons. Tapping the chat closes it. Hands back a downsized JPEG.
///
/// Present it with `View.cameraOverlay`, which shows it without the system's full-screen
/// slide so only the card moves.
struct CameraSheet: View {
    let onPhoto: (Data) -> Void
    /// Removes the overlay; called once the card has slid away.
    let onClose: () -> Void

    @State private var camera = CameraController()
    @State private var libraryItem: PhotosPickerItem?
    @State private var flash = false
    @State private var isShown = false
    /// The zoom when the current pinch began.
    @State private var pinchStart: Double?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(isShown ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityLabel("Close camera")
                    .accessibilityAddTraits(.isButton)
                ZStack(alignment: .bottom) {
                    preview
                    Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
                    controls
                }
                .frame(height: geo.size.height * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: -4)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .offset(y: isShown ? 0 : geo.size.height)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .presentationBackground(.clear)
        .onAppear { withAnimation(motion) { isShown = true } }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let photo = PhotoPreparation.jpeg(from: data) {
                    finish(with: photo)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: flash) { _, new in new }
    }

    @ViewBuilder
    private var preview: some View {
        switch camera.state {
        case .running:
            CameraPreview(session: camera.session)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? camera.zoom
                            pinchStart = start
                            camera.setZoom(start * value.magnification)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .accessibilityLabel("Camera preview")
                .accessibilityHint("Pinch to zoom")
        case .starting:
            Color(white: 0.08)
        case .denied:
            unavailable(
                "Aisle needs camera access to take a photo. You can still pick one from your library.",
                action: ("Open Settings", { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } })
            )
        case .unavailable:
            unavailable("The camera isn't available here. You can still pick a photo from your library.", action: nil)
        }
    }

    private func unavailable(_ message: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera")
                .font(.system(size: 30, weight: .semibold))
            Text(message)
                .font(.aisleSubheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .font(.aisleSubheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if camera.state == .running, camera.presets.count > 1 {
                zoomPresets
            }
            buttons
        }
    }

    /// 0.5× · 1× · 2×, like the system camera; the nearest one shows the live zoom.
    private var zoomPresets: some View {
        let active = camera.presets.min { abs($0 - camera.zoom) < abs($1 - camera.zoom) }
        return HStack(spacing: 4) {
            ForEach(camera.presets, id: \.self) { preset in
                let isActive = preset == active
                Button { camera.setZoom(preset, animated: true) } label: {
                    Text(isActive ? Self.zoomLabel(camera.zoom) + "×" : Self.zoomLabel(preset))
                        .font(.system(size: isActive ? 13 : 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Color(hex: 0xFFD872) : .white)
                        .frame(width: isActive ? 40 : 32, height: isActive ? 40 : 32)
                        .background(Circle().fill(.black.opacity(isActive ? 0.5 : 0.3)))
                }
                .accessibilityLabel("Zoom \(Self.zoomLabel(preset)) times")
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.2)))
        .animation(.easeOut(duration: 0.15), value: active)
    }

    /// "0.5", "1", "2.4": one decimal, none for whole numbers.
    static func zoomLabel(_ zoom: Double) -> String {
        let rounded = (zoom * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private var buttons: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close camera")
            Spacer()
            Button(action: capture) {
                Circle()
                    .fill(.white)
                    .frame(width: 66, height: 66)
                    .padding(5)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 3))
                    .background(Circle().fill(.black.opacity(0.25)))
            }
            .disabled(camera.state != .running || camera.isCapturing)
            .opacity(camera.state == .running ? 1 : 0.4)
            .accessibilityLabel("Take photo")
            .accessibilityIdentifier("shutterButton")
            Spacer()
            PhotosPicker(selection: $libraryItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Choose from library")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.bottom, 30)
    }

    private func capture() {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        Task {
            let data = await camera.capture()
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
            if let data, let photo = PhotoPreparation.jpeg(from: data) {
                finish(with: photo)
            }
        }
    }

    private func finish(with photo: Data) {
        onPhoto(photo)
        close()
    }

    private func close() {
        guard isShown else { return }
        withAnimation(motion) { isShown = false } completion: { onClose() }
    }
}

extension View {
    /// Shows `CameraSheet` over this screen. The cover appears and goes without its own
    /// animation; the sheet slides its card and fades the dim itself.
    func cameraOverlay(isPresented: Binding<Bool>, onPhoto: @escaping (Data) -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraSheet(onPhoto: onPhoto) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { isPresented.wrappedValue = false }
            }
        }
    }
}

/// Runs the back camera and takes one photo at a time.
///
/// Zoom is in the system camera's terms: 1 is the main lens, 0.5 the ultra-wide when the
/// phone has one, and pinching goes up to 10.
@MainActor
@Observable
final class CameraController: NSObject {
    enum State: Equatable { case starting, running, denied, unavailable }

    private(set) var state: State = .starting
    private(set) var isCapturing = false
    private(set) var zoom: Double = 1
    /// Quick zoom buttons this phone's lenses support.
    private(set) var presets: [Double] = []

    @ObservationIgnored private var device: AVCaptureDevice?
    /// The device zoom factor that shows as 1×; above 1 when an ultra-wide lens is the base.
    @ObservationIgnored private var mainLensFactor: Double = 1
    @ObservationIgnored private var zoomRange: ClosedRange<Double> = 1...1

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "aisle.camera")
    @ObservationIgnored private var pending: CheckedContinuation<Data?, Never>?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }
        // Multi-lens cameras switch lenses as you zoom; fall back to the main lens alone.
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        guard let device = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
              let input = try? AVCaptureDeviceInput(device: device) else {
            state = .unavailable
            return
        }
        let hasUltraWide = [.builtInTripleCamera, .builtInDualWideCamera].contains(device.deviceType)
        let mainLens = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1) : 1
        let lowest = device.minAvailableVideoZoomFactor / mainLens
        let highest = min(device.maxAvailableVideoZoomFactor, mainLens * 10) / mainLens
        self.device = device
        mainLensFactor = mainLens
        zoomRange = lowest...max(lowest, highest)
        presets = [0.5, 1, 2].filter { zoomRange.contains($0) }
        let session = session, output = output
        let configured: Bool = await withCheckedContinuation { done in
            queue.async {
                session.beginConfiguration()
                session.sessionPreset = .photo
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    done.resume(returning: false)
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                // Open on the main lens (1×), not the ultra-wide.
                if (try? device.lockForConfiguration()) != nil {
                    device.videoZoomFactor = mainLens
                    device.unlockForConfiguration()
                }
                session.startRunning()
                done.resume(returning: true)
            }
        }
        state = configured ? .running : .unavailable
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Zooms to `value` (1 = main lens), clamped to what the camera can do. Animated
    /// zooms ramp smoothly, for the preset buttons.
    func setZoom(_ value: Double, animated: Bool = false) {
        guard let device else { return }
        let clamped = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = clamped
        let factor = CGFloat(clamped * mainLensFactor)
        queue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 12)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
        }
    }

    /// The photo's file data, or nil if capture failed.
    func capture() async -> Data? {
        guard state == .running, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return await withCheckedContinuation { continuation in
            pending = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            self.pending?.resume(returning: data)
            self.pending = nil
        }
    }
}

/// The live camera feed, filling its frame.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

enum PhotoPreparation {
    /// Upright, at most `maxSide` points on the long edge, as JPEG: small enough to send.
    static func jpeg(from data: Data, maxSide: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
