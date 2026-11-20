import ImmerseAgent
import ImmerseCore
import SwiftUI

/// 今日简报: today's load, meetings, deadline risks, lagging goals and estimate tips, each with a one-tap fix
struct MorningBriefingView: View {
    @Environment(Secretary.self) private var secretary
    @Environment(ScheduleState.self) private var schedule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let insights = secretary.insights()
        let context = secretary.context()
        let brief = MorningBrief.make(day: .now, context: context, insights: insights)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(brief?.title ?? "今天没有安排").font(.title3.weight(.semibold))
                        if let body = brief?.body { Text(body).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    LoadRow(load: insights.today, title: "今天")
                    LoadRow(load: insights.tomorrow, title: "明天")
                    if insights.today.isOverloaded {
                        fixButton("挪走几项，减轻今天", systemImage: "arrow.right.circle") { secretary.overloadProposal(day: .now) }
                    }
                }
                if !insights.risks.isEmpty {
                    Section("截止风险") {
                        ForEach(insights.risks) { risk in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(risk.task.displayTitle).font(.headline)
                                Text(riskText(risk)).font(.caption).foregroundStyle(.secondary)
                                if risk.kind != .overdue {
                                    fixButton("看看补救方案", systemImage: "lifepreserver") { secretary.deadlineRescue(risk) }
                                }
                            }
                        }
                    }
                }
                if !insights.behindGoals.isEmpty {
                    Section("落后的目标") {
                        ForEach(insights.behindGoals, id: \.goal.id) { item in
                            HStack {
                                ProgressRing(fraction: item.progress.fraction, color: .orange).frame(width: 24, height: 24)
                                VStack(alignment: .leading) {
                                    Text(item.goal.displayTitle)
                                    Text("\(item.progress.percent)% · 还剩 \(item.progress.daysLeft) 天").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = item.progress.targetMinutes {
                                    Button("补上") {
                                        show(secretary.goalPlan(item.goal, targetMinutes: target)?.proposal)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                if !insights.calibration.isEmpty {
                    Section("估时校准") {
                        ForEach(insights.calibration) { CalibrationRow(insight: $0) }
                    }
                }
                Section {
                    LabeledContent("你的高效时段", value: insights.energy.peakHours().map { "\($0):00" }.joined(separator: "、"))
                    if !insights.energy.isPersonalized {
                        Text("专注记录还不多，先按常见作息估计，用一周后会更准").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("今日简报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func riskText(_ risk: DeadlineRiskItem) -> String {
        switch risk.kind {
        case .overdue: "已经过了截止时间 \(risk.delayDays) 天"
        case .scheduledTooLate: "排在了截止之后，会晚 \(risk.delayDays) 天"
        case .notEnoughTime: "还需要 \(DurationText.minutes(risk.requiredMinutes * 60))，截止前只有约 \(DurationText.minutes(risk.availableMinutes * 60)) 空档"
        }
    }

    private func fixButton(_ title: String, systemImage: String, make: @escaping () -> PlanProposal?) -> some View {
        Button {
            show(make())
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func show(_ proposal: PlanProposal?) {
        guard let proposal else { return }
        dismiss()
        schedule.showProposal(proposal, secretary: secretary)
    }
}

struct LoadRow: View {
    let load: DayLoad
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(DurationText.minutes(load.plannedMinutes * 60)) / \(DurationText.minutes(load.capacityMinutes * 60))")
                    .monospacedDigit()
                    .foregroundStyle(load.isOverloaded ? .orange : .secondary)
            }
            ProgressView(value: min(Double(load.plannedMinutes) / Double(max(load.capacityMinutes, 1)), 1))
                .tint(load.isOverloaded ? .orange : Palette.brand)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CalibrationRow: View {
    let insight: CalibrationInsight
    @Environment(Secretary.self) private var secretary
    @State private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(insight.message).font(.subheadline)
            Text("基于最近 \(insight.samples) 次").font(.caption).foregroundStyle(.secondary)
            if accepted {
                Label("已采纳", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            } else {
                Button("采纳") {
                    secretary.acceptCalibration(insight)
                    accepted = true
                    Haptics.success()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// 晚间复盘: how today went, and what to do with what's left
struct EveningReviewView: View {
    @Environment(Secretary.self) private var secretary
    @Environment(ScheduleState.self) private var schedule
    @Environment(\.dismiss) private var dismiss
    @State private var summaryText: String?
    @State private var carryIDs: Set<UUID> = []

    var body: some View {
        let context = secretary.context()
        let review = EveningReview.summary(for: .now, context: context)
        let insights = secretary.insights()
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        stat("完成", "\(review.done)/\(review.total)")
                        stat("专注", DurationText.minutes(review.focusedMinutes * 60))
                        stat("放弃", "\(review.interruptions) 次")
                    }
                    if let summaryText {
                        Label(summaryText, systemImage: "sparkles").font(.subheadline)
                    } else {
                        ProgressView()
                    }
                }
                if !review.unfinished.isEmpty {
                    Section {
                        ForEach(review.unfinished) { task in
                            Button {
                                if carryIDs.contains(task.id) { carryIDs.remove(task.id) } else { carryIDs.insert(task.id) }
                            } label: {
                                HStack {
                                    Image(systemName: carryIDs.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Palette.brand)
                                    Text(task.displayTitle).foregroundStyle(.primary)
                                    Spacer()
                                    Text(TimeText.hhmm(task.start, calendar: schedule.calendar)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button {
                            let tasks = review.unfinished.filter { carryIDs.contains($0.id) }
                            if let proposal = EveningReview.carryOver(tasks, from: .now, context: context)
                                .map({ ProposalValidator.validate($0, context: context) }) {
                                dismiss()
                                schedule.showProposal(proposal, secretary: secretary)
                            }
                        } label: {
                            Label("顺延选中的 \(carryIDs.count) 项到明天", systemImage: "arrow.turn.down.right")
                        }
                        .disabled(carryIDs.isEmpty)
                    } header: {
                        Text("没做完的")
                    } footer: {
                        if insights.tomorrow.isOverloaded {
                            Text("明天已经排了 \(DurationText.minutes(insights.tomorrow.plannedMinutes * 60))，顺延后可能过载").foregroundStyle(.orange)
                        }
                    }
                }
                if !insights.calibration.isEmpty {
                    Section("估时校准") {
                        ForEach(insights.calibration) { CalibrationRow(insight: $0) }
                    }
                }
            }
            .navigationTitle("今天的复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                carryIDs = Set(review.unfinished.map(\.id))
                summaryText = await secretary.reviewSummary(done: review.done, total: review.total,
                                                            focusedMinutes: review.focusedMinutes, interruptions: review.interruptions)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
