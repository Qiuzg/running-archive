import SwiftUI

struct RunFeedbackFields: View {
    @Binding var value: RunAnnotation
    var body: some View {
        Section {
            Text("整次跑步有多费力？").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(1...10, id: \.self) { level in
                    Button { value.effort = value.effort == level ? nil : level } label: {
                        Text("\(level)").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(value.effort == level ? RunTheme.accent.opacity(0.22) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("用力程度 \(level)/10")
                        .accessibilityAddTraits(value.effort == level ? .isSelected : [])
                }
            }
            Text(value.effort.map { "已选 \($0)/10 · 再点一次取消" } ?? "未填写 · 1 很轻松，10 极难")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("主观用力 · RPE") } footer: { Text("记录这次跑步整体的用力程度，不根据配速或心率代填。各项均可跳过。") }
        Section("这次跑步整体感觉如何？") {
            HStack(spacing: 5) {
                ForEach(RunFeeling.allCases) { feeling in
                    Button { value.feeling = value.feeling == feeling ? nil : feeling } label: {
                        VStack(spacing: 7) {
                            Image(systemName: feeling.symbol).font(.title3)
                            Text(feeling.title).font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(value.feeling == feeling ? RunTheme.accent.opacity(0.22) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(value.feeling == feeling ? .isSelected : [])
                }
            }
            if value.feeling == nil { Text("未填写").font(.caption).foregroundStyle(.secondary) }
        }
        Section {
            Picker("跑步结束时的疲劳", selection: $value.fatigue) {
                Text("未填写").tag(nil as RunFatigue?)
                ForEach(RunFatigue.allCases) { Text($0.title).tag(Optional($0)) }
            }
        } header: { Text("跑后疲劳") } footer: { Text("这是这次跑步结束时的主观感受。补填旧记录时，请回想当时的情况，不代表现在的恢复状态。") }
    }
}

struct RunFeedbackCard: View {
    let activity: ArchiveActivity
    @EnvironmentObject private var journal: TrainingJournal
    @EnvironmentObject private var training: AITrainingStore
    @State private var editing = false
    private var annotation: RunAnnotation { journal.annotation(activity.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("跑后感受", systemImage: "face.smiling").font(.headline)
                Spacer()
                Button(annotation.hasFeedback ? "补充 / 修改" : "填写") { editing = true }
                    .disabled(!TrainingFeedback.finished(activity, now: .now))
                    .accessibilityIdentifier("training.feedback.edit")
            }
            if annotation.hasRatings { Text(annotation.feedbackSummary).font(.subheadline) }
            else { Text("用力程度、整体感受和跑后疲劳均未填写").font(.subheadline).foregroundStyle(.secondary) }
            if !annotation.note.isEmpty { Text(annotation.note).font(.subheadline).lineLimit(3) }
            if let date = annotation.feedbackUpdatedAt, annotation.hasRatings {
                Text("感受更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            } else if annotation.hasRatings { Text("旧记录未保存填写时间").font(.caption).foregroundStyle(.secondary) }
            if let date = annotation.noteUpdatedAt, !annotation.note.isEmpty {
                Text("备注更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(annotation.sharing.title).font(.caption).foregroundStyle(.secondary)
            if annotation.hasFeedback {
                Text("这是你对这次跑步的自述，和心率负荷、成绩等客观指标分开展示。").font(.caption).foregroundStyle(.secondary)
                let shared = TrainingFeedback.shared(activities: [activity], journal: journal.data, now: .now, calendar: AIDate.localCalendar)
                if !shared.isEmpty {
                    Button(training.isWorking ? "正在更新建议…" : "用最新反馈更新计划") { RunningArchiveRuntime.shared.scheduleAnalysis(force: true) }
                        .disabled(training.isWorking || !training.configured)
                    Text(training.configured ? (training.state.configuration.automatic ? "已开启自动建议，保存获授权的反馈后会更新计划。" : "自动建议已关闭，可手动更新。") : "可在训练计划中配置 AI 后使用；本机反馈已保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("可以稍后补填。未填写不会被视为轻松或没有疲劳。").font(.caption).foregroundStyle(.secondary) }
        }.nativeCard()
            .sheet(isPresented: $editing) { AnnotationEditor(activity: activity) }
    }
}

struct TrainingFeedbackHistoryCard: View {
    @EnvironmentObject private var journal: TrainingJournal
    @EnvironmentObject private var archive: ArchiveStore
    private var recent: [ArchiveActivity] {
        TrainingFeedback.recentActivities(archive.activities, now: .now, calendar: AIDate.localCalendar, days: 14)
    }
    private var reported: [ArchiveActivity] { recent.filter { journal.annotation($0.id).hasFeedback } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("近期主观反馈", systemImage: "text.bubble").font(.headline)
            Text("近两周 \(reported.count)/\(recent.count) 次跑步有反馈").font(.subheadline)
            Text("按跑步日期回看，用力、感受和疲劳保持独立，不换算为负荷或恢复分数。").font(.caption).foregroundStyle(.secondary)
            if reported.isEmpty {
                if let latest = recent.last {
                    NavigationLink("为最近一次跑步补充反馈") { ActivityDetailView(activity: latest) }
                } else { Text("暂无近期跑步").font(.caption).foregroundStyle(.secondary) }
            } else {
                ForEach(Array(reported.suffix(3).reversed())) { activity in
                    NavigationLink { ActivityDetailView(activity: activity) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activity.date.formatted(.dateTime.month().day().hour().minute())).font(.subheadline.bold())
                            Text(journal.annotation(activity.id).feedbackSummary.isEmpty ? "已记录跑后备注" : journal.annotation(activity.id).feedbackSummary).font(.caption)
                        }.foregroundStyle(.primary)
                    }
                }
                if reported.count > 3 {
                    NavigationLink("查看近两周全部反馈") {
                        List(reported.reversed()) { activity in
                            NavigationLink { ActivityDetailView(activity: activity) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(activity.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(journal.annotation(activity.id).feedbackSummary.isEmpty ? "已记录跑后备注" : journal.annotation(activity.id).feedbackSummary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.navigationTitle("近两周跑后反馈")
                    }
                }
            }
        }.nativeCard()
    }
}

struct FeedbackPlanEvidenceView: View {
    let revision: AIPlanRevision
    var selectedIDs: Set<String> = []
    private var feedback: [RunSubjectiveFeedback] { revision.feedbackContext ?? [] }
    private var reviews: [AITrainingFeedbackReview] {
        (revision.plan.feedback_review ?? []).filter { selectedIDs.isEmpty || !Set($0.evidence_ids).isDisjoint(with: selectedIDs) }
    }
    var body: some View {
        List {
            Section {
                Text("生成于 " + revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("这里保留本版计划生成时获授权的反馈及 AI 响应。之后修改或撤回的反馈不会改变历史；新计划使用最新范围。响应说明对应生成时的 AI 安排，手动改课以当前课程为准。").font(.caption).foregroundStyle(.secondary)
            }
            if reviews.isEmpty {
                Section { Text(feedback.isEmpty ? "这版计划没有使用主观反馈。未填写或未授权不等于没有疲劳。" : "这项训练没有单独引用主观反馈。") }
            }
            ForEach(Array(reviews.enumerated()), id: \.offset) { _, review in
                Section("AI 对反馈的解释") {
                    Text(review.observation)
                    Text("对本期安排的响应").font(.subheadline.bold())
                    Text(review.plan_response)
                    ForEach(feedback.filter { review.evidence_ids.contains($0.id) }) { item in
                        DisclosureGroup("查看自述 · " + item.workout_start.formatted(date: .abbreviated, time: .shortened)) {
                            feedbackRow(item)
                        }
                    }
                }
            }
            Section("当时提供的主观反馈") {
                ForEach(feedback.filter { selectedIDs.isEmpty || selectedIDs.contains($0.id) }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.workout_start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        feedbackRow(item)
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("反馈如何影响计划").navigationBarTitleDisplayMode(.inline)
    }
    private func feedbackRow(_ item: RunSubjectiveFeedback) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let effort = item.effort_1_to_10 { Text("主观用力 \(effort)/10") }
            if let feeling = item.feeling { Text("整体感受：" + feeling.title) }
            if let fatigue = item.post_run_fatigue { Text("当次跑后疲劳：" + fatigue.title) }
            if let date = item.ratings_updated_at {
                Text("感受更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let note = item.note {
                Text(note)
                if let date = item.note_updated_at { Text("备注更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }
        }.font(.subheadline).padding(.vertical, 5)
    }
}
