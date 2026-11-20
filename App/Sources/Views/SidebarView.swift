import MacWashingKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Namespace private var highlight
    @State private var startup: Volume?
    @State private var water = WaterState()
    @State private var motion = MotionSensor()
    @State private var logoSize: CGSize = .zero
    @State private var logoOrigin: CGPoint = .zero
    /// Layout places of the floating badges (tank coordinates), by water id.
    @State private var badgeRests: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 30)

            // The logo floats on the water surface poured into the sidebar.
            BrandLogo()
                .padding(.horizontal, 6)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { logoSize = $0 }
                .modifier(FloatOnWater(state: water, id: "logo"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named("tank")).origin } action: { logoOrigin = $0 }

            VStack(spacing: 2) {
                ForEach(AppSection.modules) { section in
                    navButton(section)
                }
            }
            // The water settles two menu rows below the menu.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("tank")).maxY } action: { bottom in
                if water.restLevel == nil, bottom > 100 { water.restLevel = bottom + 2 * (Self.navRowHeight + 2) }
            }
            .padding(.top, 18)

            Spacer()

            // DevMode in debug builds, where nothing is deleted: the badge floats on its own.
            if model.dryRun {
                floating(DevModeBadge(), id: "devmode")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            Button { model.go(to: .settings) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.muted)
                        .rotationEffect(.degrees(model.section == .settings ? 90 : 0))
                        .frame(width: 28, height: 28)
                    Text("Настройки").font(.system(size: 14, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
                .hoverRow(selected: model.section == .settings, cornerRadius: 11)
            }
            .buttonStyle(.row)
            .accessibilityIdentifier("sidebar.settings")
            .accessibilityAddTraits(model.section == .settings ? .isSelected : [])
            .padding(.bottom, 8)

            diskCard
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .coordinateSpace(.named("tank"))
        .onChange(of: CGRect(origin: logoOrigin, size: logoSize), initial: true) {
            water.setRest("logo", $1, startsOnSurface: true)
        }
        .onChange(of: badgeRests, initial: true) {
            for (id, rect) in $1 { water.setRest(id, rect, startsOnSurface: false) }
        }
        .onChange(of: model.isBusy, initial: true) { water.boiling = $1 }
        // The Mac's tilt moves the water only while the app is in front and the helper can switch the sensor on.
        .onChange(of: model.isActive && model.helper.status == .enabled, initial: true) { _, live in
            motion.onSample = { [water] in water.motion($0) }
            if live { motion.start() } else { motion.stop() }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.sidebar)
                    .glassSurface(.rect(cornerRadius: 18))
                SidebarWater(state: water)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                WaterInputReader(state: water)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.sidebarStroke))
        .onAppear { startup = Volume.mounted().first(where: \.isStartup) }

    }

    private static let navRowHeight: CGFloat = 44

    private func navButton(_ section: AppSection) -> some View {
        let selected = model.section == section
        return Button { model.go(to: section) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(section.tile)
                        .shadow(color: .white.opacity(0.35), radius: 0, y: 0.5)
                    Image(systemName: section.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .scaleEffect(selected ? 1.08 : 1)
                Text(section.title)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: Self.navRowHeight)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(palette.selection)
                        .matchedGeometryEffect(id: "nav", in: highlight)
                }
            }
            .contentShape(Rectangle())
            .hoverRow(cornerRadius: 11)
        }
        .buttonStyle(.row)
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Motion.bouncy, value: selected)
    }

    /// Rides the water as its own body. The place is measured outside the float, so the water's offset is not in it.
    private func floating(_ badge: some View, id: String) -> some View {
        badge
            .modifier(FloatOnWater(state: water, id: id))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tank")) } action: { badgeRests[id] = $0 }
    }

    @ViewBuilder
    private var diskCard: some View {
        if let startup {
            VStack(alignment: .leading, spacing: 8) {
                Label(startup.name, systemImage: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(palette.disk)
                            .frame(width: proxy.size.width * Double(startup.usedBytes) / Double(max(startup.totalBytes, 1)))
                    }
                }
                .frame(height: 4)
                Text("Свободно \(ByteFormat.string(startup.availableBytes)) из \(ByteFormat.string(startup.totalBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            .padding(14)
            .card(palette, radius: 14)
        }
    }

}


/// «DevMode»: shown in debug builds, where nothing is really deleted.
struct DevModeBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Label("DevMode", systemImage: "testtube.2")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.warning)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(palette.warning.opacity(0.14)))
            .overlay(Capsule().strokeBorder(palette.warning.opacity(0.35)))
            .help(Text("Тестовый режим: файлы не удаляются"))
    }
}
