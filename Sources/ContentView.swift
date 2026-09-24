import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraController()
    @Environment(\.scenePhase) private var phase
    @State private var showControls = true
    @State private var black = false
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewView(session: cam.session, enabled: !black, version: cam.configVersion)
                .ignoresSafeArea()
                .opacity(black ? 0 : 1)

            if black {
                // Pantalla negra: sin vista previa y brillo al mínimo. Tocar para salir.
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { exitBlack() }
                    .overlay(
                        Text(cam.clientConnected ? "● Transmitiendo" : "Esperando OBS…")
                            .font(.caption2)
                            .foregroundColor(Color.white.opacity(0.25))
                            .padding(),
                        alignment: .bottomLeading)
            } else {
                HStack(alignment: .top) {
                    Spacer()
                    if showControls { panel }
                    Button {
                        withAnimation { showControls.toggle() }
                    } label: {
                        Image(systemName: showControls ? "chevron.right.circle.fill" : "slider.horizontal.3")
                            .font(.title2)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cam.start()
        }
        .onChange(of: phase) { p in
            if p == .active { cam.resume() }
        }
    }

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle()
                        .fill(cam.clientConnected ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(cam.clientConnected ? "OBS conectado" : "Esperando OBS…")
                        .font(.headline)
                }
                if cam.controlledByPC {
                    Label("Controlable desde OBS", systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Text("tcp://\(cam.address):\(String(CameraController.port))")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text(cam.status)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Picker("Lente", selection: $cam.lens) {
                    ForEach(Lens.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Resolución")
                    Spacer()
                    Picker("Resolución", selection: $cam.mode) {
                        ForEach(VideoMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Zoom %.1fx", Double(cam.zoom)))
                    Slider(value: $cam.zoom, in: 1...max(cam.maxZoom, 1.01))
                        .disabled(cam.maxZoom <= 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Balance de blancos auto", isOn: $cam.wbAuto)
                    Text("\(Int(cam.temperature)) K")
                        .foregroundColor(cam.wbAuto ? .secondary : .primary)
                    Slider(value: $cam.temperature, in: 2500...8000, step: 50)
                        .disabled(cam.wbAuto || !cam.wbSupported)
                }

                Toggle("Bloquear enfoque y exposición", isOn: $cam.aeafLocked)

                Button {
                    enterBlack()
                } label: {
                    Label("Pantalla negra (ahorro)", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .frame(width: 290)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func enterBlack() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        black = true
    }

    private func exitBlack() {
        UIScreen.main.brightness = savedBrightness
        black = false
    }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let enabled: Bool
    let version: Int // fuerza updateUIView tras reconfigurar la cámara

    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: View, context: Context) {
        guard let c = v.previewLayer.connection else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        c.isEnabled = enabled
    }
}
