//
//  LiquidGlass.swift
//  液态玻璃 (Liquid Glass) 观感组件。
//
//  macOS 26 起系统提供原生 API (.glassEffect / GlassEffectContainer / GlassButtonStyle)。
//  包的最低部署目标是 macOS 13, 所以这里统一做可用性分支: 新系统走真液态玻璃,
//  老系统回退到磨砂材质 + 描边。视图代码两边共用, 不会因为观感升级把老系统用户挡在门外。
//
//  透明度取向: 一律用 clear 玻璃而不是 regular。regular 的底色偏实, 会明显盖住背后的
//  桌面; clear 才是"通透"那一档。代价是选中/边界这类状态会变淡, 所以凡是靠玻璃本身
//  表达状态的地方 (选中块、按钮轮廓) 都补了一圈极细描边兜底, 保证可辨性不依赖玻璃浓度。
//

import SwiftUI

/// 圆角玻璃面板: 卡片底。默认 clear 玻璃 (最通透的一档)。
extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.clear.tint($0) } ?? .clear,
                             in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }

    /// 选中态玻璃: 选中的那块浮起一层可交互玻璃, 未选中用 identity 保持完全透明。
    /// 未选中必须走 identity 而不是"低透明度玻璃" —— 后者会留下可见的底板痕迹。
    @ViewBuilder
    func glassSelection(_ isOn: Bool, cornerRadius: CGFloat = 6) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(isOn ? .clear.interactive() : .identity,
                             in: .rect(cornerRadius: cornerRadius))
                // clear 玻璃太通透, 选中块几乎会"消失"。补一圈极细描边把选中态钉住,
                // 这样透明度可以放心往下降, 不必靠加浓玻璃来保证看得出选了哪个。
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                    }
                }
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
    }

    /// 液态玻璃按钮。prominent = 主操作 (极淡的着色玻璃)。
    @ViewBuilder
    func glassButton(prominent: Bool = false, cornerRadius: CGFloat = 8) -> some View {
        self.buttonStyle(ClearGlassButtonStyle(prominent: prominent, cornerRadius: cornerRadius))
    }
}

/// 通透版液态玻璃按钮样式。
///
/// 系统的 .glass / .glassProminent 用的是 regular 玻璃, 底色偏实 —— 按钮会整块盖住
/// 背后的内容。这里自绘成 clear 玻璃, 只保留很轻的按下反馈, 让弹窗整体透出去。
private struct ClearGlassButtonStyle: ButtonStyle {
    var prominent = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let pressed = configuration.isPressed
        let label = configuration.label
            .fontWeight(prominent ? .semibold : .regular)
            .padding(.horizontal, prominent ? 10 : 8)
            .padding(.vertical, prominent ? 5 : 3)
            .contentShape(shape)

        // Glass 类型本身是 macOS 26+ 才有的, 不能存进属性, 所以分支必须在这里内联
        return Group {
            if #available(macOS 26.0, *) {
                // 主操作给一点点着色以示区分, 但浓度压到刚好看得出来为止
                label.glassEffect(prominent ? .clear.tint(.accentColor.opacity(0.28)).interactive()
                                            : .clear.interactive(),
                                  in: shape)
            } else {
                label
                    .background(shape.fill(Color.primary.opacity(pressed ? 0.14 : 0.06)))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
        }
        .scaleEffect(pressed ? 0.985 : 1)
        .animation(.smooth(duration: 0.15), value: pressed)
    }
}

/// 液态玻璃分段选择器。
///
/// 系统的 segmented picker 无法自定义选中态材质 (选中块永远是系统灰),
/// 所以这里自行绘制: 每个选项是一块独立的玻璃, 选中项升起、未选中项保持透明。
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// 等宽布局: 不传则按内容自适应
    var width: CGFloat? = nil

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // 让相邻玻璃互相融合, 切换时观感是"流动"而不是"跳变"
                GlassEffectContainer(spacing: 2) { row }
            } else {
                row
            }
        }
        .frame(width: width)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                segment(opt.value, opt.label)
            }
        }
    }

    @ViewBuilder
    private func segment(_ value: Value, _ label: String) -> some View {
        let isOn = value == selection
        Button {
            guard !isOn else { return }
            withAnimation(.smooth(duration: 0.25)) { selection = value }
        } label: {
            Text(label)
                .font(.caption2)
                .fontWeight(isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSelection(isOn, cornerRadius: 6)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
