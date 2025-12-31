import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                statusCard
                startStopCard
                modeCard
                actionsCard
                gesturesCard
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Статус

    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(app.statusDot.color)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.isOnline ? "Online" : "Offline")
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {

                    Button("Пинг") { Task { await app.ping() } }
                        .font(.system(size: 12, weight: .bold))
                        .buttonStyle(.bordered)
                }
            }

            if let t = app.lastPingText {
                HStack {
                    Text("Последний пинг:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(t)
                        .font(.system(size: 12, weight: .bold))
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Запуск / стоп

    private var startStopCard: some View {
        VStack(spacing: 10) {

            Button {
                Task {
                    if app.isRunning { await app.stop() }
                    else { await app.start() }
                }
            } label: {
                HStack {
                    Image(systemName: app.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(app.isRunning ? "Остановить управление" : "Запустить управление")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text(app.isRunning ? "ВКЛ" : "ВЫКЛ")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(app.isRunning ? .green : .secondary)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.isOnline && !app.isRunning)

    
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Режимы

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Режим")
                .font(.system(size: 16, weight: .bold))

            VStack(spacing: 10) {
                Picker("Профиль", selection: $app.profile) {
                    ForEach(Profile.allCases) { p in
                        Text(profileTitleRu(p)).tag(p)
                    }
                }
                .pickerStyle(.navigationLink)

                Picker("Указатель", selection: $app.pointerMode) {
                    ForEach(PointerMode.allCases) { m in
                        Text(pointerModeTitleRu(m)).tag(m)
                    }
                }
                .pickerStyle(.navigationLink)

                VStack(spacing: 6) {
                    HStack {
                        Text("Чувствительность")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text(String(format: "%.1f", app.sensitivity))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $app.sensitivity, in: 0.5...3.0, step: 0.1)
                        .onChange(of: app.sensitivity) { _, _ in
                            app.applyRuntimeConfig()
                        }
                }

                Toggle(isOn: $app.smoothingEnabled) {
                    Text("Сглаживание движения")
                        .font(.system(size: 13, weight: .bold))
                }
                .onChange(of: app.smoothingEnabled) { _, _ in
                    app.applyRuntimeConfig()
                }

                if app.pointerMode == .clutch {
                    Text("Подсказка: в режиме «С зажимом» движение курсора работает только при удержании pinch.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Кнопки действий

    // 4 большие кнопки на весь экран (2x2). Вставь вместо текущего блока actionsCard.
    private var actionsCard: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let side = min(w, h) / 2

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quadrantButton(
                        title: "Клик",
                        systemImage: "cursorarrow.click",
                        enabled: app.isRunning
                    ) { Task { await app.quickClick() } }
                    .frame(width: side, height: side)

                    quadrantButton(
                        title: "Правый\nклик",
                        systemImage: "cursorarrow.click.2",
                        enabled: app.isRunning
                    ) { Task { await app.quickRightClick() } }
                    .frame(width: side, height: side)
                }

                HStack(spacing: 0) {
                    quadrantButton(
                        title: app.dragEnabled ? "Перетаскивание\nВКЛ" : "Перетаскивание\nВЫКЛ",
                        systemImage: app.dragEnabled ? "hand.draw.fill" : "hand.draw",
                        enabled: app.isRunning
                    ) { Task { await app.toggleDrag() } }
                    .frame(width: side, height: side)

                    quadrantButton(
                        title: "Сброс\n(центр)",
                        systemImage: "scope",
                        enabled: app.isRunning
                    ) { Task { await app.recenter() } }
                    .frame(width: side, height: side)
                }
            }
            .frame(width: w, height: h, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .frame(height: 240) // подгони под свой экран/скролл
    }

    private func quadrantButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(enabled ? 1.0 : 0.45)
    }

    // MARK: - Жесты / Логи

    private var gesturesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Жесты и события")
                .font(.system(size: 15, weight: .bold))

            Text(app.lastGestureText.isEmpty ? "Последний жест: —" : "Последний жест: \(app.lastGestureText)")
                .font(.system(size: 13, weight: .bold))

            if !app.eventLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.eventLog.prefix(5), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Событий пока нет")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private func bigButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
    }

    private func profileTitleRu(_ p: Profile) -> String {
        switch p {
        case .mouse: return "Мышь"
        case .presentation: return "Презентация"
        case .media: return "Медиа"
        case .custom: return "Пользовательский"
        }
    }

    private func pointerModeTitleRu(_ m: PointerMode) -> String {
        switch m {
        case .relative: return "Обычный (движение рукой)"
        case .clutch: return "С зажимом (pinch)"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
