import SwiftUI

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline.weight(.bold))
            Text(subtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func cardSurface(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            }
    }

    @ViewBuilder
    func inlineNavigationTitleForIOS() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

struct PrimaryCapsuleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(tint.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct DarkCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color(red: 0.1, green: 0.14, blue: 0.22).opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct SecondaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color.white.opacity(configuration.isPressed ? 0.58 : 0.82))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct FormatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.heavy))
            .foregroundStyle(Color.primary.opacity(0.8))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.52 : 0.78))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
