import AVFoundation
import SwiftUI

/// Interfaz al estilo de la app Cámara: todo abajo y compacto, para que se vea lo que se filma.
/// Una fila de lentes, una barra de íconos y, encima, solo el control que se esté ajustando.
/// Tocar la imagen oculta o muestra los controles.
struct ContentView: View {
    @StateObject private var cam = CameraController()
    @Environment(\.scenePhase) private var phase
    @State private var showControls = true
    @State private var tab: Tab?
    @State private var black = false
    @State private var savedBrightness: CGFloat = 0.5

    enum Tab: String, CaseIterable, Identifiable {
        case zoom, focus, exposure, color, video

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .zoom: return "plus.magnifyingglass"
            case .focus: return "scope"
            case .exposure: return "sun.max"
            case .color: return "thermometer"
            case .video: return "film"
            }
        }

        var title: String {
            switch self {
            case .zoom: return "Zoom"
            case .focus: return "Foco"
            case .exposure: return "Luz"
            case .color: return "Color"
            case .video: return "Video"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewView(session: cam.session, enabled: !black, portrait: cam.portrait,
                        mirrored: cam.mirrored, version: cam.configVersion)
                .ignoresSafeArea()
                .opacity(black ? 0 : 1)
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showControls.toggle() } }

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
            } else if showControls {
                VStack(spacing: 0) {
                    HStack {
                        statusPill
                        Spacer()
                    }
                    Spacer()
                    bottomPanel
                }
                .padding(10)
                .transition(.opacity)
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

    // MARK: - Arriba: estado

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(cam.clientConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            if cam.clientConnected {
                Text(cam.controlledByPC ? "OBS · control desde PC" : "OBS conectado")
            } else {
                Text("Esperando OBS · \(cam.address):\(String(CameraController.port))")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Abajo: lentes, barra de íconos y el control abierto

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let tab = tab {
                tabContent(tab)
                    .font(.footnote)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            lensRow
            toolBar
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity)
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ForEach(cam.lenses) { option in
                let selected = cam.isSelected(option)
                Button(option.label) { cam.select(option) }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selected ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                    .foregroundColor(selected ? .black : .white)
            }
        }
    }

    private var toolBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                toolButton(t.icon, t.title, active: tab == t) {
                    withAnimation(.easeOut(duration: 0.15)) { tab = (tab == t) ? nil : t }
                }
            }
            Divider().frame(height: 30)
            toolButton("rectangle.portrait", "Vertical", active: cam.portrait) { cam.portrait.toggle() }
            toolButton("arrow.left.and.right", "Espejo", active: cam.mirrored) { cam.mirrored.toggle() }
            toolButton("moon.fill", "Negra", active: false) { enterBlack() }
        }
    }

    private func toolButton(_ icon: String, _ title: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundColor(active ? .yellow : .white)
        }
    }

    @ViewBuilder
    private func tabContent(_ t: Tab) -> some View {
        switch t {
        case .zoom:
            valueRow(String(format: "%.1fx", Double(cam.zoom))) {
                Slider(value: $cam.zoom, in: 1...max(cam.maxZoom, 1.01))
                    .disabled(cam.maxZoom <= 1)
            }

        case .focus:
            VStack(spacing: 6) {
                Toggle("Enfoque automático", isOn: $cam.afAuto)
                    .disabled(!cam.manualFocusSupported)
                HStack {
                    Text("Cerca").font(.caption2)
                    Slider(value: $cam.focusPosition, in: 0...1)
                    Text("Lejos").font(.caption2)
                }
                .disabled(cam.afAuto || !cam.manualFocusSupported)
                .opacity(cam.afAuto || !cam.manualFocusSupported ? 0.4 : 1)
            }

        case .exposure:
            VStack(spacing: 6) {
                valueRow(String(format: "%+.1f EV", Double(cam.exposureBias))) {
                    Slider(value: $cam.exposureBias, in: -3...3, step: 0.1)
                }
                Toggle("Bloquear exposición", isOn: $cam.aeLocked)
            }

        case .color:
            VStack(spacing: 6) {
                Toggle("Balance de blancos automático", isOn: $cam.wbAuto)
                valueRow("\(Int(cam.temperature)) K") {
                    Slider(value: $cam.temperature, in: 2500...8000, step: 50)
                }
                .disabled(cam.wbAuto || !cam.wbSupported)
                .opacity(cam.wbAuto || !cam.wbSupported ? 0.4 : 1)
            }

        case .video:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Resolución")
                    Spacer()
                    Picker("Resolución", selection: $cam.mode) {
                        ForEach(VideoMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Text("tcp://\(cam.address):\(String(CameraController.port))")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(cam.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Valor a la izquierda (ancho fijo, para que el deslizador no salte) y control a la derecha.
    private func valueRow<Content: View>(_ value: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    // MARK: - Pantalla negra

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
    let portrait: Bool
    let mirrored: Bool
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
        // La vista previa muestra exactamente lo que se envía a OBS.
        if c.isVideoOrientationSupported { c.videoOrientation = portrait ? .portrait : .landscapeRight }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
        c.isEnabled = enabled
    }
}
