import SwiftUI

// Design system "Pro tối giản (dark)" — tokens + component dùng chung cho mọi màn.
// Mẫu thiết kế: docs/mockups/monitor-ui.html (phong cách C).
// Mục tiêu: nền tối, mật độ cao, số liệu dùng font monospaced, accent xanh lạnh.

enum Theme {
    // Nền & bề mặt
    static let bg       = Color(hex: 0x16181D)   // nền cửa sổ / detail
    static let surface  = Color(hex: 0x1C1F26)   // nền card
    static let surface2 = Color(hex: 0x232733)   // nền nhấn (row hover / control)
    static let border   = Color(hex: 0x262B34)   // viền card / lưới chart
    static let track    = Color(hex: 0x262B34)   // nền thanh tiến trình

    // Chữ
    static let textPrimary   = Color(hex: 0xE6EAF0)
    static let textSecondary = Color(hex: 0x9AA3B2)
    static let textTertiary  = Color(hex: 0x7D8696)

    // Accent
    static let accent = Color(hex: 0x4CC2FF)   // xanh lạnh — màu chủ đạo
    static let green  = Color(hex: 0x3FD08A)
    static let orange = Color(hex: 0xFFB454)
    static let red    = Color(hex: 0xFF6B5E)
    static let purple = Color(hex: 0xB68CFF)

    // Khoảng cách / bo góc
    static let gap: CGFloat    = 10
    static let pad: CGFloat    = 14
    static let radius: CGFloat = 8

    // Font số liệu (monospaced, đều cột)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// Khởi tạo từ mã hex RRGGBB (UInt32), vd 0x4CC2FF.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex         & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Component dùng chung

/// Khung màn hình: nền tối phủ kín + tiêu đề chữ hoa, cuộn dọc.
struct ProScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Text(title.uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }
}

/// Card nền tối, viền mảnh, bo góc — container chuẩn của design system.
struct ProCard<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(Theme.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// Header card: glyph accent + tiêu đề chữ hoa (kerning) + giá trị lớn (mono) bên phải.
struct CardHeader: View {
    let icon: String
    let title: String
    var value: String? = nil
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(Theme.mono(16))
                    .foregroundStyle(valueColor)
            }
        }
    }
}

/// Thanh tiến trình mảnh, bo tròn.
struct StatBar: View {
    var fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

/// Hàng "nhãn — giá trị" (giá trị dùng mono) trong card.
struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.mono(12.5))
                .foregroundStyle(valueColor)
        }
    }
}
