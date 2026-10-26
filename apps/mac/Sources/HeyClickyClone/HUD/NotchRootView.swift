import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @FocusState private var promptFocused: Bool

    private var notchHeight: CGFloat { model.geometry.notchSize.height }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(cornerRadius: model.isExpanded ? 20 : 10, ear: NotchGeometry.ear)
                .fill(Color.black)

            VStack(spacing: 0) {
                // The menu-bar band. Under a physical notch nothing can be drawn
                // here; on other displays the idle eyes live in it.
                ZStack {
                    if !model.geometry.hasNotch, model.state == .idle, !model.hovering {
                        EyesView(mood: .awake).transition(.opacity)
                    }
                }
                .frame(height: notchHeight)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, NotchGeometry.ear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { model.setHovering($0) }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.state)
        .animation(.easeOut(duration: 0.2), value: model.hovering)
        .foregroundStyle(.white)
        .onChange(of: model.state) { _, newState in
            promptFocused = (newState == .prompt)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            if model.hovering {
                HStack(spacing: 10) {
                    ClickyCharacterView(character: model.character, mood: .awake, size: 26)
                    Text("hold ⌃⌥ to talk · double-tap ⌃ to ask · click to open")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .contentShape(Rectangle())
                .onTapGesture { model.set(.home) }
                .transition(.opacity)
            }
        case .listening:
            HStack(spacing: 12) {
                EyesView(mood: .awake)
                WaveformBars()
                Text("Listening…")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .thinking:
            HStack(spacing: 12) {
                EyesView(mood: .thinking)
                ThinkingDots()
                Text("Thinking…")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .prompt:
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                TextField("Ask anything…", text: $model.promptText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($promptFocused)
                    .onSubmit { model.submitPrompt() }
                Button(action: model.submitPrompt) {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .bold))
                        .padding(6)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(model.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 10)
            .transition(.opacity)
        case .reply(let text):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ClickyCharacterView(character: model.character, mood: .happy, size: 22)
                    Text("Clicky").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if model.tellMoreAvailable {
                        Button { model.onTellMore?() } label: {
                            Label("Tell me more", systemImage: "person.fill.badge.plus")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.white.opacity(0.16)))
                        }
                        .buttonStyle(.plain)
                        .help("Hand this to Scout for a deeper walkthrough")
                    }
                    Text("esc").font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .agent(let name, let step):
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String(name.prefix(1))).font(.system(size: 13, weight: .bold))
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12, weight: .semibold))
                    Text(step).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                ThinkingDots()
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .notice(let text):
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.white.opacity(0.8))
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .dictating(let text):
            HStack(alignment: .top, spacing: 10) {
                WaveformBars().padding(.top, 2)
                Text(text.isEmpty ? "Listening… release ⌥ to insert" : text)
                    .font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? .white.opacity(0.6) : .white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .dictated(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.cursor").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).padding(.top, 2)
                Text(text).font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .home:
            HomePanelView(model: model).transition(.opacity)
        case .settings:
            SettingsPanelView(model: model).transition(.opacity)
        case .clickys:
            if let app = model.app { ClickyListView(model: model, runtime: app.agents, store: app.agents.store).transition(.opacity) }
        case .clicky(let id):
            if let app = model.app { ClickyChatView(model: model, runtime: app.agents, store: app.agents.store, agentID: id).id(id).transition(.opacity) }
        case .conversation(let c):
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader(model: model)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(c.messages.suffix(6)) { m in
                                HStack {
                                    if m.role == .user { Spacer(minLength: 60) }
                                    Text(m.text)
                                        .font(.system(size: 13))
                                        .lineSpacing(2)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(m.role == .user ? Color(nsColor: .systemBlue).opacity(0.85) : Color.white.opacity(0.1)))
                                        .frame(maxWidth: 400, alignment: m.role == .user ? .trailing : .leading)
                                    if m.role == .assistant { Spacer(minLength: 60) }
                                }
                                .id(m.id)
                            }
                            if let status = c.status {
                                HStack(spacing: 8) { ThinkingDots(); Text(status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                            }
                        }
                    }
                    .onChange(of: c.messages.count) { _, _ in if let last = c.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                if !c.chips.isEmpty || c.canClear {
                    HStack(spacing: 6) {
                        ForEach(c.chips, id: \.self) { chip in
                            Button(chip) { model.onConversationSend?(chip) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color(nsColor: .systemBlue).opacity(0.75)))
                        }
                        if c.canClear {
                            Button { model.onClearAnnotations?() } label: { Label("Clear", systemImage: "xmark").font(.system(size: 11, weight: .medium)) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(.white.opacity(0.14)))
                        }
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.system(size: 11, weight: .bold))
                        Text(c.hint).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(LinearGradient(colors: [Color(nsColor: .systemBlue), Color(nsColor: .systemBlue).opacity(0.7)], startPoint: .leading, endPoint: .trailing)))
                    TextField("Ask Dicky…", text: $model.askText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(width: 170)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .onSubmit {
                            let t = model.askText.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            model.askText = ""
                            model.onConversationSend?(t)
                        }
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        case .suggestions(let cards):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    EyesView(mood: .happy)
                    Text("Good morning. A few things your Clickys could do today.")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("esc").font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                ForEach(cards) { card in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).font(.system(size: 12, weight: .semibold))
                            Text("\(card.agentName)\(card.everyMinutes != nil ? " · repeats" : ""): \(card.task)")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button("No") { model.onSuggestion?(card, false) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        Button("Yes") { model.onSuggestion?(card, true) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        }
    }
}

// MARK: - Shape

/// Black HUD body: flat top that merges with the notch, rounded bottom corners,
/// and small concave "ears" at the top edges so it reads as part of the bezel.
struct NotchShape: Shape {
    var cornerRadius: CGFloat
    var ear: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: ear, dy: 0)
        let r = min(cornerRadius, body.height / 2, body.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + ear),
                       control: CGPoint(x: body.minX, y: body.minY))
        p.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
        p.addQuadCurve(to: CGPoint(x: body.minX + r, y: body.maxY),
                       control: CGPoint(x: body.minX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - r),
                       control: CGPoint(x: body.maxX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.maxX, y: body.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: body.maxX, y: body.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Small animated parts

struct EyesView: View {
    enum Mood { case awake, thinking, happy }
    var mood: Mood

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.4)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.4)
            let blink = t < 0.12
            HStack(spacing: 5) {
                eye(blink: blink)
                eye(blink: blink)
            }
        }
        .frame(width: 22, height: 14)
    }

    private func eye(blink: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white)
            .frame(width: 7, height: blink ? 1.5 : (mood == .happy ? 6 : 12))
            .offset(y: mood == .thinking ? -2 : 0)
            .animation(.easeInOut(duration: 0.08), value: blink)
    }
}

struct WaveformBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    let phase = t * 6 + Double(i) * 0.9
                    let h = 5 + 11 * (0.5 + 0.5 * sin(phase))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: h)
                }
            }
        }
        .frame(height: 18)
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let a = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.8))
                    Circle().fill(.white.opacity(a)).frame(width: 5, height: 5)
                }
            }
        }
    }
}
