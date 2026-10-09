import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var settings = false
    @State private var filter = 0
    @Namespace private var filterSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88) }
    private let accent = Color(red: 0.17, green: 0.42, blue: 0.87)
    var filtered: [BarItem] {
        model.items.filter { item in
            (search.isEmpty || (item.name + item.detail).localizedCaseInsensitiveContains(search)) &&
            (filter == 0 || (filter == 1 ? model.isPinned(item) : !model.isPinned(item)))
        }.sorted { a, b in
            if a.fixed != b.fixed { return !a.fixed }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 38, height: 38).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("PinBar").font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary)
                    Text("让菜单栏轻一点").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 28) }.buttonStyle(PinBarPressStyle()).help("刷新程序列表").accessibilityLabel("刷新程序列表").disabled(model.busy || model.loading)
                Button { withAnimation(motion) { settings.toggle() } } label: { Image(systemName: "gearshape").frame(width: 26, height: 28) }.buttonStyle(PinBarPressStyle()).help("设置").accessibilityLabel("设置")
                Button { model.closePanel?() } label: { Image(systemName: "xmark").frame(width: 20, height: 28) }.buttonStyle(PinBarPressStyle()).help("关闭面板").accessibilityLabel("关闭面板")
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 18)
            Divider()
            if !model.trusted { permissionView }
            else {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索菜单栏程序", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
                    }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 2) {
                        filterButton("全部", count: model.items.count, tag: 0)
                        filterButton("常驻", count: model.items.filter { model.isPinned($0) }.count, tag: 1)
                        filterButton("收起", count: model.items.filter { !model.isPinned($0) }.count, tag: 2)
                    }.padding(3).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                }.padding(.horizontal, 18).padding(.vertical, 14)
                HStack {
                    Text("菜单栏程序").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("常驻").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 2) {
                        if model.loading && model.items.isEmpty {
                            ProgressView("正在识别菜单栏…").frame(maxWidth: .infinity).padding(.top, 70)
                        } else if filtered.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                                Text(search.isEmpty ? (filter == 2 ? "菜单栏项目都在显示" : "还没有读取到菜单栏项目") : "没有找到匹配的程序").font(.system(size: 13)).foregroundStyle(.secondary)
                                if filter == 0 && search.isEmpty { Button("重新读取") { model.refresh() } }
                                if filter == 2 { Text("取消图钉，就能收起不常用的项目。").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity).padding(.top, 60)
                        } else {
                            ForEach(filtered) { item in
                                ItemRow(item: item, model: model, accent: accent)
                                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                        .animation(motion, value: filtered.map(\.id))
                }.scrollBounceBehavior(.basedOnSize)
            }
            if settings { settingsView.transition(.opacity.combined(with: .move(edge: .bottom))) }
            Divider()
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : "checkmark.circle").foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { model.toggleExpanded() } label: { Label(model.expanded ? "收起图标" : "临时展开", systemImage: model.expanded ? "chevron.left" : "chevron.right") }.buttonStyle(PinBarPressStyle()).font(.system(size: 11, weight: .medium)).foregroundStyle(accent).disabled(!model.trusted || model.busy || model.hidden.isEmpty)
                    Spacer()
                    Text(model.hoverToOpen ? "悬停轻展，移出收回" : "点亮图钉，即可常驻").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.padding(16)
        }.frame(width: 380, height: 580).background {
            ZStack {
                PinBarMaterial()
                Color(nsColor: .windowBackgroundColor).opacity(0.58)
            }
        }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 18)).tint(accent)
    }
    private func filterButton(_ title: String, count: Int, tag: Int) -> some View {
        Button { withAnimation(motion) { filter = tag } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: filter == tag ? .semibold : .medium))
                Text(count.formatted()).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(filter == tag ? .primary : .secondary).contentTransition(.numericText())
            }.frame(maxWidth: .infinity).padding(.vertical, 7)
                .background {
                    if filter == tag {
                        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "filter", in: filterSelection)
                    }
                }.contentShape(Rectangle())
        }.buttonStyle(PinBarPressStyle()).foregroundStyle(filter == tag ? .primary : .secondary)
            .accessibilityLabel("\(title) \(count)").accessibilityAddTraits(filter == tag ? .isSelected : [])
    }
    var permissionView: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pin.circle").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
            Text("菜单栏，清爽一点").font(.system(size: 25, weight: .semibold)).lineSpacing(3)
            Text("点亮图钉，让常用程序留在菜单栏。其他图标收在这里，需要时随时打开。").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("先连接你的菜单栏").font(.system(size: 13, weight: .semibold))
                Text("1. 打开下面的系统设置\n2. 在列表中找到 PinBar，打开开关\n3. 回到这里，程序列表会自动更新").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("前往系统设置") { model.requestAccess() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("我已开启，重新检查") { model.checkAccess() }.buttonStyle(.borderless).font(.system(size: 12))
            }
            if model.accessRequested {
                Text("找不到 PinBar？在系统设置中点「＋」，选择当前应用。开启后仍未连接，可退出 PinBar 再打开。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    var settingsView: some View {
        VStack(spacing: 12) {
            Divider()
            Toggle("悬停打开收纳面板", isOn: $model.hoverToOpen).font(.system(size: 12))
            Toggle("开机启动 PinBar", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) })).font(.system(size: 12))
            HStack {
                Text("退出后，收起的图标会重新显示。").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { model.quit() }.controlSize(.small)
            }
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }
}

struct ItemRow: View {
    let item: BarItem
    @ObservedObject var model: AppModel
    let accent: Color
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88) }
    private var status: String {
        if model.processingItemID == item.id { return "正在更新…" }
        if model.queuedPinIDs.contains(item.id) { return "已排队，再点图钉可取消" }
        if model.pendingOpenItemID == item.id { return "稍后打开…" }
        if item.fixed { return "系统保留" }
        if model.failedHidden.contains(item.id) { return "未能收起，点击图钉重试" }
        return model.isPinned(item) ? "显示在菜单栏" : "已收起，点击打开"
    }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.openItem(item) } label: {
                HStack(spacing: 12) {
                    Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(status).font(.system(size: 10)).foregroundStyle(.secondary).contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(PinBarPressStyle()).help("打开 \(item.name)")
            if model.processingItemID == item.id {
                ProgressView().controlSize(.small).tint(accent).frame(width: 32, height: 32).accessibilityLabel("正在更新")
                    .transition(.opacity)
            } else if item.fixed {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 32, height: 32).help("macOS 保留的系统项目")
            } else {
                Button { model.togglePin(item) } label: {
                    Image(systemName: model.queuedPinIDs.contains(item.id) ? "clock" : (model.isPinned(item) ? "pin.fill" : "pin.slash")).font(.system(size: 14)).foregroundStyle(model.isPinned(item) ? accent : Color.secondary).frame(width: 32, height: 32)
                        .contentTransition(.symbolEffect(.replace))
                        .background(model.isPinned(item) ? accent.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(PinBarPressStyle()).help(model.isPinned(item) ? "收起 \(item.name)" : "常驻显示 \(item.name)")
                    .accessibilityLabel(model.isPinned(item) ? "收起 \(item.name)" : "常驻显示 \(item.name)")
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(model.processingItemID == item.id ? accent.opacity(0.045) : (hovered ? Color.primary.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 11))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(motion, value: model.processingItemID == item.id)
            .animation(motion, value: model.isPinned(item))
            .animation(motion, value: model.queuedPinIDs.contains(item.id))
    }
}
