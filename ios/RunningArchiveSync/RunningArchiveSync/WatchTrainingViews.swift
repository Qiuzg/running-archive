import SwiftUI

struct WatchPlanSyncCard: View {
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var watch: WatchPlanSyncStore
    @State private var settingsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Watch", systemImage: "applewatch").font(.headline)
            Text("将本期待跑训练放进手表自带的“体能训练”，跑步时按分段提示。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button(watch.hasConfigured ? "更新手表上的本期安排" : "发送本期训练到 Apple Watch") {
                Task { await training.syncWatch(requestAuthorization: true) }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .accessibilityIdentifier("training.watch.sync")
            .disabled(watch.isWorking || training.isWorking)
            if watch.isWorking { ProgressView("正在更新安排…").font(.caption) }
            else if !watch.status.isEmpty { Text(watch.status).font(.caption).foregroundStyle(.secondary) }
            if let error = watch.errorMessage ?? settingsError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if watch.hasConfigured {
                Toggle("新计划和手动修改自动同步", isOn: Binding(get: { watch.automaticUpdates }, set: { value in
                    do {
                        try watch.setAutomaticUpdates(value)
                        if value { Task { await training.syncWatch() } }
                    } catch { settingsError = error.localizedDescription }
                })).font(.subheadline).disabled(watch.isWorking)
            }
            Text(watch.hasConfigured ? "仅更新本 App 的待跑安排，已完成训练保留；系统同步到手表可能需要一些时间。" : "首次发送需授权，并开启后续更新同步；之后可以关闭。系统同步到手表可能需要一些时间。")
                .font(.caption).foregroundStyle(.secondary)
        }.nativeCard()
    }
}

struct RunWorkoutSections: View {
    let workout: RunWorkoutStructure
    var body: some View {
        Section("热身") { stepRow(workout.warmup) }
        ForEach(Array(workout.blocks.enumerated()), id: \.offset) { index, block in
            Section("训练组 \(index + 1) · \(block.repetitions) 次") {
                ForEach(Array(block.steps.enumerated()), id: \.offset) { _, interval in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(interval.purpose.title).font(.subheadline.bold())
                        stepRow(interval.step)
                    }
                }
                if block.repetitions > 1 {
                    Text("以上所有分段依次执行 \(block.repetitions) 轮，最后一轮也包含列出的恢复段。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("放松") { stepRow(workout.cooldown) }
    }
    private func stepRow(_ step: RunWorkoutStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.goalText).font(.headline)
            Text(step.instructions).font(.subheadline)
            if let target = step.targetText { Text(target).font(.subheadline).foregroundStyle(.secondary) }
            if step.goal == .distance {
                Text(String(format: "预计 %g 分钟；达到距离后进入下一段", step.seconds / 60))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AITrainingSessionEditor: View {
    @EnvironmentObject private var training: AITrainingStore
    @Environment(\.dismiss) private var dismiss
    let original: AITrainingSession
    var onSaved: (String) -> Void
    @State private var date: Date
    @State private var kind: AITrainingKind
    @State private var intensity: String
    @State private var purpose: String
    @State private var workout: RunWorkoutStructure
    @State private var error: String?
    @State private var confirmReset = false
    @State private var editMode: EditMode = .inactive

    init(session: AITrainingSession, onSaved: @escaping (String) -> Void) {
        original = session
        self.onSaved = onSaved
        _date = State(initialValue: AIDate.parse(session.date, calendar: AIDate.localCalendar) ?? .now)
        _kind = State(initialValue: session.kind)
        _intensity = State(initialValue: session.intensity)
        _purpose = State(initialValue: session.purpose)
        _workout = State(initialValue: (try? session.resolvedWorkout()) ?? (try? RunWorkoutStructure.legacy(session)) ?? RunWorkoutStructure())
    }

    private var dates: [Date] {
        (training.current?.plan.sessions ?? []).compactMap { AIDate.parse($0.date, calendar: AIDate.localCalendar) }
            .filter { $0 >= AIDate.localCalendar.startOfDay(for: .now) }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let first = dates.first, let last = dates.last { DatePicker("训练日期", selection: $date, in: first...last, displayedComponents: .date) }
                    Picker("训练类型", selection: $kind) {
                        ForEach(AITrainingKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("训练目的").font(.caption).foregroundStyle(.secondary)
                        TextField("训练目的", text: $purpose, axis: .vertical)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("强度说明").font(.caption).foregroundStyle(.secondary)
                        TextField("强度说明", text: $intensity, axis: .vertical)
                    }
                } footer: {
                    Text("手动修改会保留，之后的 AI 新计划不会覆盖该日；可随时恢复 AI 安排。改期只能选择本期休息日。")
                }
                if kind != .rest {
                    Section {
                        Text(String(format: "含重复次数的%@总用时：%g 分钟", workout.allSteps.contains(where: { $0.goal == .distance }) ? "预计" : "", workout.seconds / 60))
                        if original.workout == nil {
                            Text("旧计划尚未确认可执行分段，请检查跑步段、恢复段及重复次数后保存。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("热身") { stepLink("热身", step: $workout.warmup) }
                    ForEach(workout.blocks.indices, id: \.self) { index in
                        Section("训练组 \(index + 1)") {
                            Stepper("整组重复 \(workout.blocks[index].repetitions) 次", value: $workout.blocks[index].repetitions, in: 1...50)
                                .accessibilityIdentifier("training.block.\(index).repetitions")
                            ForEach(workout.blocks[index].steps.indices, id: \.self) { stepIndex in
                                NavigationLink {
                                    RunIntervalEditor(interval: $workout.blocks[index].steps[stepIndex])
                                } label: {
                                    let interval = workout.blocks[index].steps[stepIndex]
                                    LabeledContent(interval.purpose.title, value: interval.step.goalText)
                                }
                                .accessibilityIdentifier("training.block.\(index).step.\(stepIndex)")
                            }
                            .onDelete { workout.blocks[index].steps.remove(atOffsets: $0) }
                            .onMove { workout.blocks[index].steps.move(fromOffsets: $0, toOffset: $1) }
                            Menu("添加分段", systemImage: "plus") {
                                Button("跑步段") { workout.blocks[index].steps.append(.init()) }
                                Button("恢复段") { workout.blocks[index].steps.append(.init(purpose: .recovery, step: .init(value: 120, instructions: "慢跑或步行恢复"))) }
                            }
                            Button("删除这一组", role: .destructive) { workout.blocks.remove(at: index) }
                        }
                    }
                    Section {
                        Button("添加训练组", systemImage: "plus") { workout.blocks.append(.init()) }
                    } footer: {
                        Text("一轮会执行组内全部分段。若最后一轮不需要恢复，把最后一个跑步段单独放在下一组。可左划删除分段，点“排序”调整段落顺序。")
                    }
                    Section("放松") { stepLink("放松", step: $workout.cooldown) }
                }
                if training.state.manualOverrides?.contains(where: { $0.session.date == original.date }) == true {
                    Section { Button("恢复这一天的 AI 安排", role: .destructive) { confirmReset = true } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("修改训练").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode == .active ? "完成排序" : "排序") { editMode = editMode == .active ? .inactive : .active }
                }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("training.editor.save") }
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.interactively)
            .modifier(WorkoutKeyboardToolbar())
            .confirmationDialog("恢复 AI 安排会移除这一天的手动修改，并同步更新已发送的课程。", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("恢复 AI 安排", role: .destructive) {
                    do { try training.restoreAISession(on: original.date); onSaved(original.date); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func stepLink(_ title: String, step: Binding<RunWorkoutStep>) -> some View {
        NavigationLink { RunWorkoutStepEditor(step: step, title: title) } label: { LabeledContent(title, value: step.wrappedValue.goalText) }
    }

    private func save() {
        var session = original
        session.date = AIDate.key(date, calendar: AIDate.localCalendar)
        session.kind = kind
        session.intensity = intensity
        session.purpose = purpose
        if kind == .rest {
            session.workout = nil; session.steps = []; session.duration_minutes = 0
            session.distance_km = nil; session.pace_seconds_per_km_min = nil; session.pace_seconds_per_km_max = nil
        } else { session.applyWorkout(workout) }
        do {
            try training.editSession(originalDate: original.date, session: session)
            onSaved(session.date)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RunIntervalEditor: View {
    @Binding var interval: RunWorkoutInterval
    var body: some View {
        Form {
            Section {
                Picker("分段类型", selection: $interval.purpose) {
                    ForEach(RunStepPurpose.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            RunWorkoutStepFields(step: $interval.step)
        }.navigationTitle("修改分段").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively).modifier(WorkoutKeyboardToolbar())
    }
}

private struct RunWorkoutStepEditor: View {
    @Binding var step: RunWorkoutStep
    let title: String
    var body: some View {
        Form { RunWorkoutStepFields(step: $step) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively).modifier(WorkoutKeyboardToolbar())
    }
}

private struct RunWorkoutStepFields: View {
    @Binding var step: RunWorkoutStep
    private var reminder: Binding<Int> {
        Binding(get: { step.pace_min != nil ? 1 : step.heart_rate_min != nil ? 2 : 0 }, set: { value in
            step.pace_min = value == 1 ? 360 : nil; step.pace_max = value == 1 ? 420 : nil
            step.heart_rate_min = value == 2 ? 130 : nil; step.heart_rate_max = value == 2 ? 150 : nil
        })
    }
    var body: some View {
        Section("结束条件") {
            Picker("分段目标", selection: $step.goal) {
                ForEach(RunStepGoal.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("training.step.goal").onChange(of: step.goal) { _, goal in
                step.value = goal == .time ? 300 : 1000
                step.estimated_seconds = goal == .distance ? 360 : nil
            }
            if step.goal == .time {
                numeric("时长（分钟）", value: Binding(get: { step.value / 60 }, set: { step.value = $0 * 60 }))
            } else {
                numeric("距离（米）", value: $step.value)
                numeric("预计用时（分钟）", value: Binding(get: { (step.estimated_seconds ?? 0) / 60 }, set: { step.estimated_seconds = $0 * 60 }))
                Text("达到距离即换段；预计时间只用于计算计划总用时。").font(.caption).foregroundStyle(.secondary)
            }
            TextField("这一段怎么跑", text: $step.instructions, axis: .vertical)
        }
        Section {
            Picker("强度提醒", selection: reminder) {
                Text("不设置").tag(0); Text("配速范围").tag(1); Text("心率范围").tag(2)
            }
            if step.pace_min != nil {
                paceField("最快配速", value: $step.pace_min)
                paceField("最慢配速", value: $step.pace_max)
            } else if step.heart_rate_min != nil {
                numeric("最低心率", value: Binding(get: { step.heart_rate_min ?? 0 }, set: { step.heart_rate_min = $0 }))
                numeric("最高心率", value: Binding(get: { step.heart_rate_max ?? 0 }, set: { step.heart_rate_max = $0 }))
            }
        } footer: {
            Text("手动提醒由你指定，请检查默认值是否适合自己；不设置时，按强度说明完成。")
        }
    }
    private func numeric(_ label: String, value: Binding<Double>) -> some View {
        WorkoutNumberField(label: label, value: value)
    }
    private func paceField(_ title: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("分钟", selection: Binding(get: { Int(value.wrappedValue ?? 360) / 60 }, set: { minute in
                value.wrappedValue = Double(minute * 60 + Int(value.wrappedValue ?? 360) % 60)
            })) { ForEach(2...20, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden()
            Text(":")
            Picker("秒", selection: Binding(get: { Int(value.wrappedValue ?? 360) % 60 }, set: { second in
                value.wrappedValue = Double(Int(value.wrappedValue ?? 360) / 60 * 60 + second)
            })) { ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.labelsHidden()
            Text("/km").foregroundStyle(.secondary)
        }
    }
}

private struct WorkoutNumberField: View {
    let label: String
    @Binding var value: Double
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: $value, format: .number)
                .multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(width: 120)
                .focused($focused).accessibilityIdentifier("training.field.\(label)")
        }
        .contentShape(Rectangle()).onTapGesture { focused = true }
        .accessibilityElement(children: .contain)
    }
}

private struct WorkoutKeyboardToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar { ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                .accessibilityIdentifier("training.keyboard.done")
        } }
    }
}
