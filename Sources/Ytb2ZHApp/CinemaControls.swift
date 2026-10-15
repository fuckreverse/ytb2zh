import SwiftUI

@MainActor
struct CinemaTextFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        CinemaFieldChrome { configuration.textFieldStyle(.plain) }
    }
}

private struct CinemaFieldChrome<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        content().font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 10)
            .focused($focused)
            .background(AppTheme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? AppTheme.accent : AppTheme.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct CinemaToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.font(.system(size: 13)).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Capsule().fill(configuration.isOn ? AppTheme.accent : Color.secondary.opacity(0.22))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(3)
                    }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
            .accessibilityValue(configuration.isOn ? L("开启") : L("关闭"))
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct CinemaForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity).padding(24)
        }.background(AppTheme.canvas)
    }
}

struct CinemaSection<Content: View>: View {
    private let content: Content
    private let heading: AnyView
    private let footnote: AnyView
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.content = content(); heading = AnyView(Text(L(title))); footnote = AnyView(EmptyView())
    }
    init(@ViewBuilder content: () -> Content) {
        self.content = content(); heading = AnyView(EmptyView()); footnote = AnyView(EmptyView())
    }
    init<Header: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); heading = AnyView(header()); footnote = AnyView(EmptyView())
    }
    init<Header: View, Footer: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); heading = AnyView(header()); footnote = AnyView(footer())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            footnote.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
    }
}

struct CinemaList<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, content: content).padding(20)
        }.background(AppTheme.canvas)
    }
}

struct CinemaOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

struct CinemaSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [CinemaOption<Value>]
    @State private var expanded = false
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, selection: Binding<Value>, options: [CinemaOption<Value>]) {
        self.title = title; _selection = selection; self.options = options
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 12) {
                Text(options.first(where: { $0.value == selection })?.title ?? L10n.tr("请选择"))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
                .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(expanded ? AppTheme.accent : AppTheme.border))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(title.isEmpty ? L("选择选项") : L(title))
            .accessibilityValue(options.first(where: { $0.value == selection })?.title ?? "")
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }.padding(8)
                }.frame(width: 340, height: min(CGFloat(options.count) * 40 + 16, 330))
                    .background(AppTheme.surface)
            }
    }
    private func optionRow(_ option: CinemaOption<Value>) -> some View {
        let selected = selection == option.value
        return Button { selection = option.value; expanded = false } label: {
            HStack(spacing: 14) {
                Text(option.title).frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
            }.font(.system(size: 12)).padding(10)
                .background(selected ? AppTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

struct CinemaDisclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { isExpanded.toggle() } label: {
                HStack { label(); Spacer(); Image(systemName: isExpanded ? "minus" : "plus").foregroundStyle(AppTheme.accent) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(isExpanded ? L("已展开") : L("已折叠"))
            if isExpanded { content() }
        }
    }
}

struct CinemaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.isEnabled) private var enabled
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 4)
                Capsule().fill(AppTheme.accent).frame(width: max(4, geo.size.width * fraction), height: 4)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.2), radius: 3)
                    .offset(x: max(0, (geo.size.width - 12) * fraction))
            }.frame(height: 26).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    let raw = range.lowerBound + min(1, max(0, event.location.x / max(1, geo.size.width))) * (range.upperBound - range.lowerBound)
                    value = min(range.upperBound, max(range.lowerBound, range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step))
                })
        }.frame(height: 26).opacity(enabled ? 1 : 0.4)
            .accessibilityElement().accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
            }
    }
}

struct CinemaLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.role == .destructive ? Color.red : AppTheme.accent)
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

struct CinemaMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.borderlessButton)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))
    }
}

struct CinemaProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label
            if let fraction = configuration.fractionCompleted {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(AppTheme.accent).frame(width: geo.size.width * min(1, max(0, fraction)))
                    }
                }.frame(height: 4)
            } else {
                CinemaSpinner()
            }
            configuration.currentValueLabel
        }
    }
}

private struct CinemaSpinner: View {
    @State private var rotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().trim(from: 0.05, to: 0.78).stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 16, height: 16).rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear { if !reduceMotion { rotating = true } }
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .accessibilityLabel("正在加载")
    }
}

/// Sheets start a new presentation environment, so apply product styles explicitly.
struct CinemaPresentation<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .buttonStyle(CinemaButtonStyle())
            .textFieldStyle(CinemaTextFieldStyle())
            .toggleStyle(CinemaToggleStyle())
            .menuStyle(CinemaMenuStyle())
            .progressViewStyle(CinemaProgressStyle())
            .labeledContentStyle(CinemaLabeledContentStyle())
            .tint(AppTheme.accent)
            .background(AppTheme.canvas)
    }
}

struct CinemaLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 20) {
            configuration.label.font(.system(size: 13)).frame(minWidth: 110, alignment: .leading)
            Spacer(minLength: 0)
            configuration.content
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
    }
}
