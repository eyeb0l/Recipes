import RecipeCore
import SwiftUI
import UIKit

struct CookModeView: View {
    let session: CookSession
    let recipe: RecipeV1?
    let onSessionChanged: (CookSession) -> Void
    let onExit: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mutationError: String?
    @State private var previousIdleTimerSetting = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    cookHeader(at: context.date)
                    if let recipe, !recipe.prepTasks.isEmpty {
                        prepChecklist(recipe)
                    }
                    if let stage = session.focusedStage {
                        focusedStage(stage, at: context.date)
                    } else if session.isComplete {
                        completionCard
                    }
                    runningTimers(at: context.date)
                    readyStages
                    completedStages
                }
                .frame(maxWidth: 1_120, alignment: .leading)
                .padding(horizontalSizeClass == .compact ? 18 : 36)
                .frame(maxWidth: .infinity)
            }
        }
        .background(RecipeTheme.paper.ignoresSafeArea())
        .navigationTitle(session.recipeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            setIdleTimer(enabled: true)
            await reconcileLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            setIdleTimer(enabled: phase == .active)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
        }
    }

    private func cookHeader(at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cook mode")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .accessibilityIdentifier("cook-mode-title")
                    .tracking(1.3)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                Text("\(session.completedStageIDs.count) of \(session.stages.count) stages")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            if session.runningTimerCount > 0 {
                Label("\(session.runningTimerCount) running", systemImage: "timer")
                    .foregroundStyle(RecipeTheme.focusText)
            }
            if let mutationError {
                Text(mutationError)
                    .font(.footnote)
                    .foregroundStyle(RecipeTheme.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func prepChecklist(_ recipe: RecipeV1) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recipe.prepTasks.sorted { $0.sortIndex < $1.sortIndex }) { task in
                    let complete = session.completedPrepTaskIDs.contains(task.id)
                    Button {
                        Task { await setPrepTask(task.id, completed: !complete) }
                    } label: {
                        Label(task.instruction, systemImage: complete ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(complete ? RecipeTheme.secondaryInk : RecipeTheme.ink)
                    .accessibilityValue(complete ? "Completed" : "Not completed")
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Prep checklist")
                .font(.headline)
        }
        .padding(18)
        .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func focusedStage(_ stage: CookStageSnapshot, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(stage.action)
                        .font(.system(horizontalSizeClass == .compact ? .largeTitle : .largeTitle, design: .serif, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    if let temperature = stage.temperature {
                        Label(temperature.displayString, systemImage: "thermometer.medium")
                    }
                    if let heat = stage.heat {
                        Label(heat, systemImage: "flame")
                    }
                }
                Spacer()
                Text("Next")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RecipeTheme.focus.opacity(0.16), in: Capsule())
            }

            Text(stage.instruction)
                .font(.system(horizontalSizeClass == .compact ? .title2 : .largeTitle, design: .rounded, weight: .regular))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)

            if !stage.ingredientNames.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Bring in")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                    Text(stage.ingredientNames.joined(separator: " · "))
                        .font(.title3.weight(.semibold))
                }
            }

            if let cue = stage.completionCue {
                Label(cue, systemImage: "eye")
                    .font(.title3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RecipeTheme.stage, in: RoundedRectangle(cornerRadius: 10))
            }

            if !stage.timers.isEmpty {
                ViewThatFits {
                    HStack(spacing: 12) { timerButtons(stage, at: date) }
                    VStack(spacing: 10) { timerButtons(stage, at: date) }
                }
            }

            Button {
                Task { await complete(stage.id) }
            } label: {
                Label("Complete stage", systemImage: "checkmark")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("complete-stage")
        }
        .padding(horizontalSizeClass == .compact ? 22 : 32)
        .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(RecipeTheme.focus, lineWidth: 2)
        }
        .shadow(color: RecipeTheme.ink.opacity(0.07), radius: 18, y: 8)
    }

    @ViewBuilder
    private func timerButtons(_ stage: CookStageSnapshot, at date: Date) -> some View {
        ForEach(stage.timers) { timer in
            let state = session.timers.first { $0.id == "\(stage.id):\(timer.id)" }
            Button {
                Task { await toggle(timer, stageID: stage.id) }
            } label: {
                Label(timerLabel(timer, state: state, at: date), systemImage: state?.status == .running ? "pause.fill" : "timer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(state?.status == .finished ? RecipeTheme.warning : RecipeTheme.focus)
        }
    }

    @ViewBuilder
    private func runningTimers(at date: Date) -> some View {
        let timers = session.timers.filter { $0.status == .running || $0.status == .paused || $0.status == .finished }
        if !timers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Timers")
                    .font(.title2.weight(.semibold))
                ForEach(timers) { timer in
                    HStack(spacing: 14) {
                        Image(systemName: timerIcon(timer.status))
                            .foregroundStyle(timer.status == .finished ? RecipeTheme.warning : RecipeTheme.focus)
                        VStack(alignment: .leading) {
                            Text(timer.label).font(.headline)
                            Text(timer.status == .finished ? "Finished" : duration(timer.secondsRemaining(at: date)))
                                .monospacedDigit()
                                .foregroundStyle(RecipeTheme.secondaryInk)
                        }
                        Spacer()
                        if let stage = session.stages.first(where: { $0.id == timer.stageID }) {
                            Text(stage.action).font(.subheadline).foregroundStyle(RecipeTheme.secondaryInk)
                        }
                        if timer.status == .running || timer.status == .paused {
                            Button("Cancel timer", systemImage: "xmark") {
                                Task { await cancel(timer.id) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel \(timer.label)")
                        }
                    }
                    .padding(14)
                    .background(RecipeTheme.stage, in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }
    }

    @ViewBuilder
    private var readyStages: some View {
        let ready = session.readyStageIDs.compactMap { id in session.stages.first { $0.id == id } }
            .filter { $0.id != session.focusedStageID }
        if !ready.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready in parallel")
                    .font(.title2.weight(.semibold))
                ForEach(ready) { stage in
                    Button {
                        Task { await focus(stage.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stage.action).font(.headline)
                                Text(stage.instruction).lineLimit(2).foregroundStyle(RecipeTheme.secondaryInk)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .padding(16)
                        .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var completedStages: some View {
        let completed = session.stages.filter { session.completedStageIDs.contains($0.id) }
        if !completed.isEmpty {
            DisclosureGroup("Completed (\(completed.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(completed) { stage in
                        Label(stage.action, systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.top, 8)
                .opacity(0.48)
            }
        }
    }

    private var completionCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .foregroundStyle(RecipeTheme.focus)
            Text("All stages complete")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            Button("Return to recipe", action: onExit)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func timerLabel(_ timer: StageTimer, state: CookTimerState?, at date: Date) -> String {
        guard let state else { return "\(timer.label) · \(duration(timer.durationSeconds))" }
        switch state.status {
        case .running: return "Pause · \(duration(state.secondsRemaining(at: date)))"
        case .paused: return "Resume · \(duration(state.secondsRemaining(at: date)))"
        case .finished: return "Restart · Finished"
        case .cancelled: return "Start · \(duration(timer.durationSeconds))"
        }
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
    }

    private func timerIcon(_ status: CookTimerStatus) -> String {
        switch status {
        case .running: "timer"
        case .finished: "bell.fill"
        case .paused: "pause.circle"
        case .cancelled: "xmark.circle"
        }
    }

    private func setPrepTask(_ taskID: String, completed: Bool) async {
        await mutate { try await CookSessionStore.shared.setPrepTask(taskID, completed: completed, sessionID: session.id) }
    }

    private func focus(_ stageID: String) async {
        await mutate { try await CookSessionStore.shared.focus(stageID: stageID, sessionID: session.id) }
    }

    private func complete(_ stageID: String) async {
        await mutate { try await CookSessionStore.shared.complete(stageID: stageID, sessionID: session.id) }
    }

    private func toggle(_ timer: StageTimer, stageID: String) async {
        await mutate { try await CookSessionStore.shared.toggleTimer(sessionID: session.id, stageID: stageID, timer: timer) }
    }

    private func cancel(_ timerID: String) async {
        await mutate { try await CookSessionStore.shared.cancelTimer(timerID: timerID, sessionID: session.id) }
    }

    private func mutate(_ operation: () async throws -> CookSession) async {
        do {
            let updated = try await operation()
            mutationError = nil
            onSessionChanged(updated)
            await CookTimerNotifications.sync(session: updated)
            await CookActivityController.startOrUpdate(session: updated)
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func reconcileLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            if let updated = try? await CookSessionStore.shared.reconcileTimers(sessionID: session.id), updated != session {
                onSessionChanged(updated)
                await CookActivityController.startOrUpdate(session: updated)
            }
        }
    }

    @MainActor
    private func setIdleTimer(enabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = enabled ? true : previousIdleTimerSetting
    }
}

private extension CookingTemperature {
    var displayString: String {
        "\(NSDecimalNumber(decimal: value))°\(unit == .celsius ? "C" : "F")"
    }
}
