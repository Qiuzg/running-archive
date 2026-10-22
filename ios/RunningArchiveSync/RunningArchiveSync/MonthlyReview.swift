import SwiftUI
import Photos

struct MonthlyReviewView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State var month: Date
    @State private var selectedDay: Int?
    @State private var sharing = false
    @State private var editingGoal = false
    @AppStorage("monthlyDistanceGoals") private var goalsJSON = "{}"

    private var report: MonthlyReport { MonthlyReport(month: month, activities: store.activities) }
    private var goals: [String: Double] { (try? JSONDecoder().decode([String: Double].self, from: Data(goalsJSON.utf8))) ?? [:] }
    private var goal: Double { goals[report.key] ?? 0 }

    var body: some View {
        let data = report
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                monthPicker(data)
                hero(data)
                if goal > 0 { goalCard(data) }
                else {
                    Button("设置月度跑量目标（可选）") { editingGoal = true }
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("跑步日历").font(.headline)
                        Spacer()
                        Text("\(data.activeDays) 天留下足迹").font(.caption).foregroundStyle(.secondary)
                    }
                    MonthlyCalendar(report: data, selectedDay: selectedDay, opensSingleActivity: true) { day in
                        selectedDay = selectedDay == day ? nil : day
                    }
                    Text("日期下为公里数 · 单次直接查看，多次筛选记录")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(18).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22))
                NavigationLink { TrainingAnalysisModule(section: .structure, month: data.start) } label: {
                    HStack {
                        Label("本月跑量与频率", systemImage: "chart.bar")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.font(.subheadline).padding(16).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                weeklyDistribution(data)
                records(data).id("month-records")
            }
            .padding(18)
        }
        .onChange(of: selectedDay) { _, day in
            if day != nil { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("month-records", anchor: .top) } }
        }
        }
        .background(RunTheme.page).foregroundStyle(RunTheme.ink)
        .navigationTitle("月度统计").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享月报").disabled(data.activities.isEmpty)
            }
        }
        .sheet(isPresented: $sharing) { MonthlyShareView(report: data) }
        .sheet(isPresented: $editingGoal) {
            MonthlyGoalEditor(title: data.title, initial: goal) { value in
                var updated = goals
                if value > 0 { updated[data.key] = value } else { updated.removeValue(forKey: data.key) }
                if let encoded = try? JSONEncoder().encode(updated), let json = String(data: encoded, encoding: .utf8) { goalsJSON = json }
            }
        }
    }

    private func monthPicker(_ data: MonthlyReport) -> some View {
        HStack {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("上个月")
            Spacer()
            VStack(spacing: 4) {
                Text(data.title).font(.title2.bold())
                Text(data.isCurrent ? "本月进行中" : "月度跑量统计")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            }
            Spacer()
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(data.start >= Calendar.current.dateInterval(of: .month, for: .now)!.start)
                .accessibilityLabel("下个月")
        }
        .buttonStyle(.plain)
    }

    private func hero(_ data: MonthlyReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(data.distanceText).font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-1).minimumScaleFactor(0.5).lineLimit(1)
                Text("km").font(.title3).foregroundStyle(RunTheme.route)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top) {
                metric("跑步次数", "\(data.activities.count) 次")
                metric("累计用时", data.durationText)
                metric("平均配速", data.paceText)
            }
            Rectangle().fill(RunTheme.ink.opacity(0.10)).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(RunTheme.route)
                Text(data.comparisonLabel).font(.caption)
                Spacer(minLength: 2)
                Text(data.changeText).font(.subheadline.bold()).fixedSize()
            }
            .foregroundStyle(.secondary)
            Button { sharing = true } label: {
                Label("生成本月跑步海报", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(RunTheme.accent, in: Capsule())
            }
            .disabled(data.activities.isEmpty).opacity(data.activities.isEmpty ? 0.4 : 1)
        }
        .foregroundStyle(RunTheme.ink).padding(22)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2).opacity(0.65)
            Text(value).font(.system(.subheadline, design: .rounded, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalCard(_ data: MonthlyReport) -> some View {
        Button { editingGoal = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("本月跑量目标", systemImage: "scope").font(.subheadline.bold())
                    Spacer()
                    Text(goal > 0 ? "调整" : "设置目标").font(.caption.bold()).foregroundStyle(RunTheme.accent)
                }
                if goal > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int((data.distance / goal * 100).rounded()))%")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Spacer()
                        Text(String(format: "%.1f / %g km", data.distance, goal)).font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(data.distance / goal, 1)).tint(RunTheme.accent)
                    Text(data.distance >= goal ? "本月目标已达成" : String(format: "距目标还有 %.1f km", goal - data.distance))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("给这个月定一个自己的目标，随时查看进度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }

    private func weeklyDistribution(_ data: MonthlyReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这个月的节奏").font(.headline)
            if let longest = data.longest {
                NavigationLink(value: longest) {
                    HStack {
                        Image(systemName: "flag.checkered").foregroundStyle(RunTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("最长的一次").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.2f km", longest.distanceKm)).font(.title3.bold())
                        }
                        Spacer()
                        Text(longest.date.formatted(.dateTime.month().day())).font(.caption)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }.buttonStyle(.plain)
            }
            ForEach(data.weeks) { week in
                HStack(spacing: 12) {
                    Text(week.label).font(.caption2).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(RunTheme.route.opacity(0.10))
                        Capsule().fill(RunTheme.route)
                            .frame(width: max(0, geo.size.width * week.distance / max(data.weeks.map(\.distance).max() ?? 0, 1)))
                    }.frame(height: 7)
                    Text(String(format: "%.1f", week.distance)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
            Text("周一至周日 · 仅统计本月日期 · 单位 km").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22))
    }

    private func records(_ data: MonthlyReport) -> some View {
        let filtered = selectedDay.map { day in data.days[day - 1].activities } ?? data.activities
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedDay.map { "\(data.monthNumber) 月 \($0) 日" } ?? "本月全部跑步").font(.headline)
                Spacer()
                if selectedDay != nil { Button("查看全月") { selectedDay = nil }.font(.caption) }
                Text("\(filtered.count) 次").font(.caption).foregroundStyle(.secondary)
            }
            if filtered.isEmpty {
                Text(selectedDay == nil ? "这个月还没有跑步记录" : "这一天没有跑步记录")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            LazyVStack(spacing: 0) {
                ForEach(filtered) { activity in
                    NavigationLink(value: activity) {
                        HStack(spacing: 14) {
                            VStack(spacing: 2) {
                                Text(activity.date.formatted(.dateTime.day())).font(.title2.bold())
                                Text(activity.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
                            }.frame(width: 40)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(activity.name).font(.subheadline.bold()).lineLimit(1)
                                Text("\(activity.duration)  ·  \(activity.pace) /km").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(String(format: "%.2f", activity.distanceKm)).font(.system(.title3, design: .rounded, weight: .bold))
                                Text("km").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 16).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func moveMonth(_ offset: Int) {
        month = Calendar.current.date(byAdding: .month, value: offset, to: report.start)!
        selectedDay = nil
    }
}

struct MonthlyCalendar: View {
    let report: MonthlyReport
    var selectedDay: Int? = nil
    var poster = false
    var opensSingleActivity = false
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: poster ? 14 : 10) {
            HStack {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { item in
                    Text(item.element).font(.system(size: poster ? 15 : 11, weight: .medium))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            // A regular grid renders every day reliably in ImageRenderer, including six-row months.
            Grid(horizontalSpacing: poster ? 10 : 4, verticalSpacing: poster ? 10 : 7) {
                ForEach(0..<((report.leadingDays + report.days.count + 6) / 7), id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let index = row * 7 + col - report.leadingDays
                            if report.days.indices.contains(index) {
                                let day = report.days[index]
                                if opensSingleActivity, day.activities.count == 1, let activity = day.activities.first {
                                    NavigationLink(value: activity) { cell(day) }.buttonStyle(.plain)
                                        .accessibilityLabel("\(day.number) 日，\(String(format: "%.1f", day.distance)) 公里，查看跑步详情")
                                } else if let onSelect {
                                    Button { onSelect(day.number) } label: { cell(day) }.buttonStyle(.plain)
                                        .accessibilityLabel("\(day.number) 日，\(day.activities.count) 次跑步，\(String(format: "%.1f", day.distance)) 公里")
                                } else { cell(day) }
                            } else { Color.clear.frame(maxWidth: .infinity).frame(height: poster ? 58 : 49) }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: MonthlyReport.Day) -> some View {
        let active = !day.activities.isEmpty
        return VStack(spacing: poster ? 5 : 4) {
            Text("\(day.number)").font(.system(size: poster ? 20 : 13, weight: active ? .bold : .regular, design: .rounded))
            Text(active ? String(format: "%.1f", day.distance) : "·")
                .font(.system(size: poster ? 13 : 9, weight: .medium)).opacity(active ? 0.85 : 0.3)
        }
        .frame(maxWidth: .infinity).frame(height: poster ? 58 : 49)
        .foregroundStyle(active ? (poster ? Color.white : RunTheme.ink) : .secondary)
        .background(active ? (poster ? RunTheme.accent : RunTheme.route.opacity(0.16)) : Color.clear, in: RoundedRectangle(cornerRadius: poster ? 15 : 12))
        .overlay(RoundedRectangle(cornerRadius: poster ? 15 : 12).stroke(selectedDay == day.number ? RunTheme.accent : .clear, lineWidth: 2))
    }
}

private struct MonthlyGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: Double
    let save: (Double) -> Void
    @State private var value = ""
    private var number: Double? { Double(value.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    HStack {
                        TextField("输入目标跑量", text: $value).keyboardType(.decimalPad)
                        Text("km").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("目标只应用于这个月，可以随时调整。输入 1–10,000 km，记录会自动计入进度。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if initial > 0 {
                        Button("移除本月目标", role: .destructive) { save(0); dismiss() }
                    }
                }
            }
            .navigationTitle("跑量目标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if let number { save(number); dismiss() } }
                        .disabled(number == nil || !(number! >= 1 && number! <= 10000))
                }
            }
            .onAppear { value = initial > 0 ? String(format: "%g", initial) : "" }
        }.presentationDetents([.medium, .large])
    }
}

struct MonthlyPoster: View {
    let report: MonthlyReport
    var dark = false
    private var ink: Color { dark ? Color(red: 0.93, green: 0.95, blue: 0.93) : Color(red: 0.08, green: 0.15, blue: 0.17) }
    private var paper: Color { dark ? Color(red: 0.045, green: 0.09, blue: 0.105) : Color(red: 0.975, green: 0.967, blue: 0.945) }
    private var accent: Color { Color(red: 0.94, green: 0.34, blue: 0.22) }
    private var longestDay: MonthlyReport.Day? { report.days.max { $0.distance < $1.distance } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("RUNNING ARCHIVE").font(.system(size: 11, weight: .semibold)).tracking(2.2)
                }
                Spacer()
                Text(report.key.replacingOccurrences(of: "-", with: " / "))
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).opacity(0.6)
            }
            .padding(.bottom, 34)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(report.monthNumber) 月，跑过的日子")
                        .font(.system(size: 29, weight: .medium))
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(report.distanceText)
                            .font(.system(size: 80, weight: .medium, design: .rounded)).tracking(-3)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("km").font(.system(size: 22)).foregroundStyle(accent)
                    }
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 8) {
                    Text("本月记录").font(.system(size: 13)).opacity(0.55)
                    Text("\(report.activities.count) 次跑步").font(.system(size: 21, weight: .medium))
                    Text("\(report.activeDays) 个训练日").font(.system(size: 14)).opacity(0.6)
                }.padding(.top, 9)
            }
            .padding(.bottom, 28)
            Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
            HStack {
                Text("每日跑量").font(.system(size: 16, weight: .medium))
                Text("/ km").font(.system(size: 12)).opacity(0.5)
                Spacer()
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("最长单日").font(.system(size: 11)).opacity(0.6)
            }.padding(.top, 26)
            dailyBars.frame(height: 325).padding(.top, 16)
            HStack {
                Text("01—\(report.days.count) 日").font(.system(size: 11).monospacedDigit())
                Spacer()
                Text(report.isCurrent ? "本月截至今日" : "同日多次跑步按公里数合计")
                    .font(.system(size: 11))
            }.opacity(0.48).padding(.top, 10).padding(.bottom, 30)
            HStack(alignment: .top, spacing: 20) {
                posterMetric("累计用时", report.durationText)
                posterMetric("平均配速", report.paceText, unit: "/km")
                posterMetric("最长单日", String(format: "%.1f", longestDay?.distance ?? 0), unit: "km")
            }
            .padding(.top, 24)
            .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.14)).frame(height: 1) }
            Spacer(minLength: 20)
            HStack(alignment: .lastTextBaseline) {
                Text("MONTHLY JOURNAL").font(.system(size: 10, weight: .medium)).tracking(2)
                Spacer()
                Text(report.title).font(.system(size: 11))
            }.opacity(0.45)
        }
        .padding(44).frame(width: 720, height: 960)
        .foregroundStyle(ink).background(paper)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var dailyBars: some View {
        Canvas { context, size in
            let maxValue = report.days.map(\.distance).max() ?? 0
            let step = max(5, ceil(maxValue / 5 / 5) * 5)
            let ceiling = max(step, ceil(maxValue / step) * step)
            let plot = CGRect(x: 28, y: 45, width: size.width - 32, height: size.height - 72)
            let slot = plot.width / Double(report.days.count)
            let width = min(11, slot * 0.56)
            for tick in stride(from: 0.0, through: ceiling, by: step) {
                let y = plot.maxY - tick / ceiling * plot.height
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(ink.opacity(tick == 0 ? 0.18 : 0.07)), style: StrokeStyle(lineWidth: 0.6))
                context.draw(Text(String(format: "%.0f", tick)).font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)), at: CGPoint(x: 17, y: y), anchor: .trailing)
            }
            var labels: [CGRect] = []
            for day in report.days {
                let x = plot.minX + (Double(day.number) - 0.5) * slot
                if day.distance > 0 {
                    let h = day.distance / ceiling * plot.height
                    let rect = CGRect(x: x - width / 2, y: plot.maxY - h, width: width, height: h)
                    let peak = abs(day.distance - maxValue) < 0.001
                    context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(peak ? accent : Color(red: 0.29, green: 0.57, blue: 0.55)))
                    let value = String(format: "%.1f", day.distance)
                    let labelWidth = Double(value.count) * 6.2
                    var center = CGPoint(x: x, y: rect.minY - 11)
                    var bounds = CGRect(x: x - labelWidth / 2, y: center.y - 6, width: labelWidth, height: 12)
                    // Stagger adjacent labels when a runner has trained on consecutive days.
                    while labels.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(bounds) }) {
                        center.y -= 15; bounds.origin.y -= 15
                    }
                    labels.append(bounds)
                    context.draw(Text(value).font(.system(size: 10, weight: peak ? .bold : .medium)).foregroundStyle(peak ? accent : ink.opacity(0.8)), at: center)
                }
                context.draw(Text("\(day.number)").font(.system(size: 9).monospacedDigit()).foregroundStyle(ink.opacity(0.6)), at: CGPoint(x: x, y: plot.maxY + 18))
            }
        }
    }

    private func posterMetric(_ label: String, _ value: String, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(label).font(.system(size: 12)).opacity(0.55)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
                if !unit.isEmpty { Text(unit).font(.system(size: 12)).opacity(0.55) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonthlyShareView: View {
    @Environment(\.dismiss) private var dismiss
    let report: MonthlyReport
    @State private var dark = false
    @State private var image: UIImage?
    @State private var share = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("配色", selection: $dark) {
                        Text("暖白").tag(false)
                        Text("深绿").tag(true)
                    }.pickerStyle(.segmented)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.1), radius: 15, y: 5)
                    } else { ProgressView().frame(height: 300) }
                    Text("3:4 月度海报 · 1080 × 1440 · 适合朋友圈、小红书与聊天")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button { saveImage() } label: {
                            Label(saving ? "保存中" : "保存相册", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(image == nil || saving)
                        Button { share = true } label: {
                            Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(RunTheme.accent).disabled(image == nil)
                    }
                }.padding(20)
            }
            .background(RunTheme.page).navigationTitle("分享月度手记").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: dark) {
                image = nil
                await Task.yield()
                guard !Task.isCancelled else { return }
                let renderer = ImageRenderer(content: MonthlyPoster(report: report, dark: dark))
                renderer.scale = 1.5
                image = renderer.uiImage
                if image == nil { message = "图片生成失败，请重新打开月报后重试。" }
            }
            .sheet(isPresented: $share) { if let image { ShareSheet(items: [image]) } }
            .alert("月度手记", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func saveImage() {
        guard let image else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                message = "请在系统设置中允许添加照片，然后重试。"; return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                message = "月报已保存到相册"
            } catch { message = "保存失败：\(error.localizedDescription)" }
        }
    }
}
