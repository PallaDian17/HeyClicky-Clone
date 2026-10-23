import SwiftUI

/// Skills library: the bundled power-ups, switchable per Clicky. A skill is a
/// SKILL.md folder under the Clicky's .claude/skills/, so a switch copies or
/// removes that folder; the Clicky sees the change on its next turn.
struct SkillsPage: View {
    @ObservedObject var store: AgentStore
    @State private var skills = AgentStore.bundledSkills()
    @State private var installed: [UUID: Set<String>] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills").font(.title2.weight(.semibold))
                    Text("Power-ups each Clicky can lean on. Switch one on for a Clicky and it is ready on the next turn. Your own skills go in the Clicky's folder under .claude/skills.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(skills, id: \.name) { skill in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(skill.name).font(.headline)
                        Text(skill.description).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            ForEach(store.agents) { agent in
                                Toggle(isOn: Binding(
                                    get: { installed[agent.id]?.contains(skill.name) ?? false },
                                    set: { on in
                                        if on { store.installSkill(named: skill.name, for: agent) } else { store.uninstallSkill(named: skill.name, for: agent) }
                                        refresh()
                                    })) {
                                    HStack(spacing: 6) {
                                        AgentAvatar(agent: agent, size: 18)
                                        Text(agent.name).font(.caption)
                                    }
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(skill.url) }.controlSize(.small)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(24)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        skills = AgentStore.bundledSkills()
        var map: [UUID: Set<String>] = [:]
        for agent in store.agents { map[agent.id] = store.installedSkills(for: agent) }
        installed = map
    }
}

/// Suggestions page: what the morning cards offered today, with Yes/No, plus a
/// button to ask again.
struct SuggestionsPage: View {
    @ObservedObject var suggestions: MorningSuggestions
    @ObservedObject var store: AgentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggestions").font(.title2.weight(.semibold))
                        Text("Things your Clickys could do today, drawn from what they have done before. Yes on a repeating one makes a routine.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if suggestions.isLoading { ProgressView().controlSize(.small) }
                    Button("Ask again") { Task { await suggestions.show(force: true, present: false) } }
                        .disabled(suggestions.isLoading)
                }
                if suggestions.cards.isEmpty {
                    Text(suggestions.lastFetched == nil ? "Nothing yet. The notch offers cards once a morning, or press Ask again." : "No open suggestions. Press Ask again for fresh ones.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(suggestions.cards) { card in
                    HStack(alignment: .top, spacing: 12) {
                        if let agent = store.agents.first(where: { $0.slug == card.agentSlug }) { AgentAvatar(agent: agent, size: 30) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).font(.headline)
                            Text("\(card.agentName)\(card.everyMinutes != nil ? " · repeats" : ""): \(card.task)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("No") { suggestions.answer(card, accepted: false) }
                        Button("Yes") { suggestions.answer(card, accepted: true) }.buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                }
                if !suggestions.answered.isEmpty {
                    Text("Earlier today").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(suggestions.answered, id: \.card.id) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.accepted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(item.accepted ? .green : .secondary)
                            Text(item.card.title).font(.callout)
                            Text(item.card.agentName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
