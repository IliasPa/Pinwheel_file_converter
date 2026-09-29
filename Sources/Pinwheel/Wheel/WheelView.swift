import SwiftUI
import PinwheelCore

struct WheelView: View {
    @ObservedObject var model: WheelModel

    static let diameter: CGFloat = 260
    static let hubRadius: CGFloat = 50

    var body: some View {
        ZStack {
            WheelBackdrop(diameter: Self.diameter)
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            hub
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .scaleEffect(model.isPresented ? 1 : 0.55)
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hub: some View {
        VStack(spacing: 2) {
            Image(systemName: model.mode == .tools ? "wrench.and.screwdriver" : "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(model.fileCount == 1 ? "1 file" : "\(model.fileCount) files")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.hubRadius * 2, height: Self.hubRadius * 2)
        .background(Circle().fill(Color.primary.opacity(0.06)))
        .animation(.spring(duration: 0.25), value: model.mode)
    }
}
