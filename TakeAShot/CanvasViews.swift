import SwiftUI

struct DottedCanvasBackground: View {
    var body: some View {
        Color(red: 0.13, green: 0.18, blue: 0.27)
            .overlay {
                Canvas { context, size in
                    let dotColor = Color.white.opacity(0.12)
                    for x in stride(from: 0.0, through: size.width, by: 18) {
                        for y in stride(from: 0.0, through: size.height, by: 18) {
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                                with: .color(dotColor)
                            )
                        }
                    }
                }
            }
    }
}

struct EditableShotPreview: View {
    private let baseSize = CGSize(width: 680, height: 390)

    var body: some View {
        GeometryReader { proxy in
            let scale = min((proxy.size.width - 32) / baseSize.width, (proxy.size.height - 56) / baseSize.height)

            ZStack {
                MockScreenshot()
                    .frame(width: baseSize.width, height: baseSize.height)

                AnnotationOverlay()
                    .frame(width: baseSize.width, height: baseSize.height)
            }
            .scaleEffect(max(0.42, min(scale, 0.82)))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2 + 12)
        }
    }
}

struct MockScreenshot: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Circle().fill(.yellow).frame(width: 10, height: 10)
                Circle().fill(.green).frame(width: 10, height: 10)
                Text("app.example.test/billing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.91, green: 0.94, blue: 0.98))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Northstar")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)

                    ForEach(["Dashboard", "Billing", "Usage", "Settings"], id: \.self) { item in
                        Text(item)
                            .font(.caption.weight(item == "Billing" ? .bold : .regular))
                            .foregroundStyle(item == "Billing" ? .white : .white.opacity(0.6))
                            .padding(.horizontal, item == "Billing" ? 8 : 0)
                            .padding(.vertical, item == "Billing" ? 6 : 0)
                            .background(item == "Billing" ? Color.white.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Spacer()
                }
                .frame(width: 112)
                .padding(14)
                .background(Color(red: 0.08, green: 0.12, blue: 0.2))

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review invoice before renewal")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                        }
                        Spacer()
                        Button("Update plan") {
                        }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white)
                        .foregroundStyle(Color(red: 0.1, green: 0.14, blue: 0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(18)
                    .background(
                        LinearGradient(colors: [.blue, Color(red: 0.13, green: 0.5, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 8) {
                        MetricCard(title: "Seats", value: "18")
                        MetricCard(title: "Usage", value: "74%")
                        MetricCard(title: "Due", value: "$486")
                    }

                    VStack(spacing: 0) {
                        InvoiceRow(title: "Pro seats", value: "$360")
                        InvoiceRow(title: "Storage", value: "$86")
                        InvoiceRow(title: "Support", value: "$40")
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
                .background(Color(red: 0.96, green: 0.98, blue: 1))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 26, y: 16)
    }
}

struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct InvoiceRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).fontWeight(.bold)
        }
        .font(.caption)
        .foregroundStyle(Color(red: 0.26, green: 0.32, blue: 0.42))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }
}

struct AnnotationOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: width * 0.72, height: height * 0.52)
                    .position(x: width * 0.51, y: height * 0.56)

                Text("Add renewal warning here")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .position(x: width * 0.38, y: height * 0.39)

                Rectangle()
                    .fill(Color.yellow.opacity(0.3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.yellow, lineWidth: 3)
                    }
                    .frame(width: width * 0.42, height: 32)
                    .position(x: width * 0.66, y: height * 0.51)

                ArrowShape()
                    .stroke(Color.red.opacity(0.86), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: width * 0.42, height: 92)
                    .position(x: width * 0.64, y: height * 0.52)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .frame(width: width * 0.38, height: 58)
                    .position(x: width * 0.64, y: height * 0.64)
            }
        }
    }
}

struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.86, y: rect.minY + 18))
        path.move(to: CGPoint(x: rect.maxX * 0.86, y: rect.minY + 18))
        path.addLine(to: CGPoint(x: rect.maxX * 0.72, y: rect.minY + 10))
        path.move(to: CGPoint(x: rect.maxX * 0.86, y: rect.minY + 18))
        path.addLine(to: CGPoint(x: rect.maxX * 0.78, y: rect.minY + 34))
        return path
    }
}

struct FloatingQuickActions: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(["lock", "text.viewfinder", "doc.on.doc", "square.and.arrow.up"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(6)
        .background(Color(red: 0.1, green: 0.14, blue: 0.22).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
    }
}
