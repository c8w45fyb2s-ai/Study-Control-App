import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private enum ChatScrollAnchor {
    static let conversationEnd = "chat-conversation-end"
}

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("chat.draft.question") private var inputText = ""
    @State private var editingPlanDraft: AIPlanDraft?
    @State private var openedSource: SourceReference?
    @State private var shouldFollowConversationEnd = true

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allowModelRequests: Bool {
        store.snapshot.settings.allowModelRequests
    }

    private var hasAIConnection: Bool { store.isAIConnectionReady }

    private var modelUnavailableMessage: String? {
        if !allowModelRequests {
            return "AI 请求已关闭，开启后才能发送问题。"
        }
        if !hasAIConnection {
            return "请先配置当前 AI 服务的协议、地址、模型和鉴权方式。"
        }
        return nil
    }

    private var sendUnavailableMessage: String? {
        guard !trimmedInput.isEmpty else { return nil }
        return modelUnavailableMessage
    }

    private var canSend: Bool {
        !trimmedInput.isEmpty && !store.isBusy && modelUnavailableMessage == nil
    }

    private var canUseAssistant: Bool {
        modelUnavailableMessage == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatWorkbenchHeader(
                referenceCount: store.chatContexts.count,
                includesPersonalContext: store.snapshot.settings.includePersonalContextInAnswers,
                allowModelRequests: allowModelRequests,
                hasAPIKey: hasAIConnection,
                answerMode: store.snapshot.settings.answerMode,
                isBusy: store.isBusy,
                activeRequestTitle: store.activeAIRequestTitle
            )

            if let modelUnavailableMessage {
                ChatReadinessCard(message: modelUnavailableMessage) {
                    store.navigateToSettings()
                }
                .padding(.horizontal, StudyDesign.Spacing.wide)
                .padding(.top, StudyDesign.Spacing.tight)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
                        if store.snapshot.chatMessages.isEmpty && canUseAssistant {
                            ChatWorkbenchEmptyState { prompt in
                                inputText = prompt
                            }
                        } else {
                            ForEach(Array(store.snapshot.chatMessages.enumerated()), id: \.element.id) { index, message in
                                if shouldShowDateSeparator(before: message, at: index) {
                                    ChatDateSeparator(date: message.createdAt)
                                        .id("date-\(message.id.uuidString)")
                                }

                                ChatBubble(
                                    message: message,
                                    planDraft: store.snapshot.aiPlanDraft(for: message),
                                    onCopyText: { text, label in
                                        copyTextToPasteboard(text)
                                        store.statusMessage = "\(label)已复制"
                                    },
                                    onReusePrompt: { prompt in
                                        inputText = prompt
                                        shouldFollowConversationEnd = false
                                        store.statusMessage = "已放回输入框"
                                    },
                                    onConfirmPlan: { draft in
                                        store.requestAIPlanDraftConfirmation(draft)
                                    },
                                    onEditPlan: { draft in
                                        editingPlanDraft = draft
                                    },
                                    onDismissPlan: { draft in
                                        store.dismissAIPlanDraft(draft)
                                    },
                                    onOpenReviews: {
                                        store.navigateToReviews()
                                    },
                                    onOpenCitation: { citation in
                                        if let reference = citation.sourceReference {
                                            openedSource = reference
                                        } else {
                                            store.navigateToCitation(citation)
                                        }
                                    }
                                )
                                    .id(message.id)
                            }
                        }

                        if store.isBusy {
                            TypingIndicator()
                                .id("typing-indicator")
                        }

                        if !store.chatContexts.isEmpty {
                            RetrievedContextList(items: store.chatContexts)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollAnchor.conversationEnd)
                    }
                    .padding(StudyDesign.Spacing.wide)
                    .frame(maxWidth: StudyDesign.Layout.readingMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !shouldFollowConversationEnd {
                        Button {
                            shouldFollowConversationEnd = true
                            scrollToConversationEnd(proxy, force: true)
                        } label: {
                            Label("回到底部", systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
                        .padding(.trailing, StudyDesign.Spacing.relaxed)
                        .padding(.bottom, StudyDesign.Spacing.normal)
                        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
                        .accessibilityLabel("回到最新消息")
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            shouldFollowConversationEnd = false
                        }
                )
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.snapshot.chatMessages.count) { _, _ in
                    scrollToConversationEnd(proxy)
                }
                .onChange(of: store.isBusy) { _, _ in
                    scrollToConversationEnd(proxy)
                }
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canUseAssistant {
                ChatInputDock(
                    text: $inputText,
                    canSend: canSend,
                    isBusy: store.isBusy,
                    hasMessages: !store.snapshot.chatMessages.isEmpty,
                    referenceCount: store.chatContexts.count,
                    includesPersonalContext: store.snapshot.settings.includePersonalContextInAnswers,
                    answerMode: store.snapshot.settings.answerMode,
                    sendUnavailableMessage: sendUnavailableMessage,
                    onSend: sendQuestion,
                    onCancel: {
                        store.cancelAIRequest()
                    },
                    onClear: {
                        store.clearChatHistory()
                    },
                    onOpenSettings: {
                        store.navigateToSettings()
                    },
                    onTogglePersonalContext: togglePersonalContext
                )
            }
        }
        .background(ChatWorkbenchBackground())
        .dismissKeyboardOnTapOutside()
        .sheet(item: $editingPlanDraft) { draft in
            AIPlanDraftEditSheet(
                draft: draft,
                onSave: { updatedDraft in
                    store.updateAIPlanDraft(updatedDraft)
                    editingPlanDraft = nil
                },
                onConfirm: { updatedDraft in
                    if store.updateAIPlanDraft(updatedDraft) {
                        store.requestAIPlanDraftConfirmation(updatedDraft)
                    }
                    editingPlanDraft = nil
                },
                onDismissDraft: { draft in
                    store.dismissAIPlanDraft(draft)
                    editingPlanDraft = nil
                }
            )
        }
        .sheet(isPresented: Binding(get: { openedSource != nil }, set: { if !$0 { openedSource = nil } })) {
            if let openedSource { SourceLocationView(reference: openedSource).environmentObject(store) }
        }
    }

    private func shouldShowDateSeparator(before message: ChatHistoryMessage, at index: Int) -> Bool {
        let messages = store.snapshot.chatMessages
        guard index > 0, messages.indices.contains(index - 1) else { return true }
        return !Calendar.current.isDate(message.createdAt, inSameDayAs: messages[index - 1].createdAt)
    }

    private func sendQuestion() {
        guard canSend else { return }
        store.chatQuestion = trimmedInput
        store.askQuestion()
        inputText = ""
        shouldFollowConversationEnd = true
    }

    private func togglePersonalContext() {
        store.updatePersonalContextInAnswers(!store.snapshot.settings.includePersonalContextInAnswers)
    }

    private func scrollToConversationEnd(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || shouldFollowConversationEnd else { return }
        Task { @MainActor in
            await Task.yield()
            if store.isBusy {
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    proxy.scrollTo("typing-indicator", anchor: .bottom)
                }
            } else if let last = store.snapshot.chatMessages.last {
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    proxy.scrollTo(ChatScrollAnchor.conversationEnd, anchor: .bottom)
                }
            }
        }
    }
}

private struct ChatReadinessCard: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: "gearshape.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.info)
                .frame(width: 38, height: 38)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .stroke(StudyDesign.Colors.info.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text("完成模型设置后开始答疑")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button(action: action) {
                StudyActionPillLabel(title: "去设置", systemImage: "arrow.right")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .soft, size: .compact, minWidth: 86))
            .help("打开设置")
            .accessibilityLabel("去设置")
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private func copyTextToPasteboard(_ text: String) {
#if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
#elseif canImport(UIKit)
    UIPasteboard.general.string = text
#endif
}

private struct ChatDateSeparator: View {
    let date: Date

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().weekday(.wide))
    }

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.42))
                .frame(height: 1)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
                .padding(.horizontal, StudyDesign.Spacing.compact)
                .padding(.vertical, 4)
                .background(StudyDesign.Colors.dataBackground, in: Capsule())
                .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
                .fixedSize()

            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.42))
                .frame(height: 1)
        }
        .frame(maxWidth: 760)
        .padding(.vertical, StudyDesign.Spacing.micro)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("聊天日期：\(title)")
    }
}

private struct ChatWorkbenchHeader: View {
    let referenceCount: Int
    let includesPersonalContext: Bool
    let allowModelRequests: Bool
    let hasAPIKey: Bool
    let answerMode: AIAnswerMode
    let isBusy: Bool
    let activeRequestTitle: String

    private var statusTitle: String {
        if isBusy {
            return activeRequestTitle.isEmpty ? "AI 请求中" : activeRequestTitle
        }
        if !allowModelRequests {
            return "AI 请求已关闭"
        }
        if !hasAPIKey {
            return "AI 服务未就绪"
        }
        return "AI 服务已配置"
    }

    private var statusIcon: String {
        if isBusy { return "waveform" }
        if !allowModelRequests { return "lock.slash" }
        if !hasAPIKey { return "key" }
        return "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if isBusy { return StudyDesign.Colors.info }
        if !allowModelRequests { return StudyDesign.Colors.danger }
        if !hasAPIKey { return StudyDesign.Colors.warning }
        return StudyDesign.Colors.success
    }

    private var contextTitle: String {
        includesPersonalContext ? "个人资料检索" : "通用回答"
    }

    private var referenceTitle: String {
        referenceCount == 0 ? "暂无候选资料" : "\(referenceCount) 条候选资料"
    }

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            StudyPageHeader(
                title: "学习答疑",
                subtitle: isBusy ? statusTitle : answerMode.label,
                icon: "bubble.left.and.bubble.right.fill",
                compact: true
            )

            Spacer(minLength: StudyDesign.Spacing.tight)

            if isBusy || !allowModelRequests || !hasAPIKey {
                ChatWorkbenchStatusPill(title: statusTitle, icon: statusIcon, tint: statusTint)
            } else if referenceCount > 0 {
                ChatWorkbenchStatusPill(title: referenceTitle, icon: "quote.bubble", tint: StudyDesign.Colors.info)
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.relaxed)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .background {
            StudyDesign.Gradients.chromeSurface
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudyDesign.Colors.cardBackground)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("学习助手，\(statusTitle)，\(referenceTitle)，\(contextTitle)，\(answerMode.label)")
    }
}

private struct ChatWorkbenchStatusPill: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .foregroundStyle(StudyDesign.Colors.labelPrimary)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(Capsule().fill(StudyDesign.Colors.inputBackground))
        .overlay(
            Capsule()
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct ChatWorkbenchEmptyState: View {
    let onSelectPrompt: (String) -> Void

    private static let prompts: [WorkbenchStarterPrompt] = [
        WorkbenchStarterPrompt(
            icon: "doc.text.magnifyingglass",
            title: "整理薄弱点",
            prompt: "根据我的知识点、错题和笔记，整理我现在最需要复习的薄弱点。",
            tint: StudyDesign.Colors.secondary
        ),
        WorkbenchStarterPrompt(
            icon: "calendar.badge.clock",
            title: "生成复习计划",
            prompt: "根据我的近期学习资料，生成一份今天可以执行的复习计划。",
            tint: StudyDesign.Colors.warning
        ),
        WorkbenchStarterPrompt(
            icon: "xmark.circle.fill",
            title: "分析错因",
            prompt: "帮我从最近的错题里找出重复出现的错因，并给出练习建议。",
            tint: StudyDesign.Colors.danger
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.relaxed) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                AssistantAvatar(isThinking: false)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("开始一次学习分析")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("选择一个入口，或直接在下方输入你的问题。")
                        .font(.subheadline)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach(Self.prompts) { prompt in
                        WorkbenchStarterCard(prompt: prompt, onSelect: onSelectPrompt)
                    }
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    ForEach(Self.prompts) { prompt in
                        WorkbenchStarterCard(prompt: prompt, onSelect: onSelectPrompt)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: StudyDesign.Layout.readingMaxWidth)
        .padding(StudyDesign.Spacing.relaxed)
        .background(StudyDesign.Gradients.featureSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.secondary)
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
    }
}

private struct WorkbenchStarterPrompt: Identifiable {
    let icon: String
    let title: String
    let prompt: String
    let tint: Color

    var id: String { prompt }
}

private struct WorkbenchStarterCard: View {
    let prompt: WorkbenchStarterPrompt
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            onSelect(prompt.prompt)
        } label: {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: prompt.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(prompt.tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(StudyDesign.Colors.dataBackground))

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(prompt.prompt)
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: StudyDesign.Spacing.compact)

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(StudyDesign.Spacing.tight)
            .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(prompt.prompt)
    }
}

struct ChatBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    var message: ChatHistoryMessage
    var planDraft: AIPlanDraft?
    var onCopyText: (String, String) -> Void
    var onReusePrompt: (String) -> Void
    var onConfirmPlan: (AIPlanDraft) -> Void
    var onEditPlan: (AIPlanDraft) -> Void
    var onDismissPlan: (AIPlanDraft) -> Void
    var onOpenReviews: () -> Void
    var onOpenCitation: (ChatMessageCitation) -> Void

    private var isUser: Bool {
        message.role == .user
    }

    private var timestampText: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private var messagePreview: String {
        let trimmed = message.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 140 else { return trimmed }
        return "\(trimmed.prefix(140))..."
    }

    private var messageAccessibilityLabel: String {
        let author = isUser ? "你发送的问题" : "学习助手回复"
        let citationText = message.citations.isEmpty ? "无引用" : "\(message.citations.count) 条引用"
        return "\(author)，\(timestampText)，\(citationText)。\(messagePreview)"
    }

    private var messageAccessibilityHint: String {
        if isUser {
            return "这是你发给 AI 工作台的问题。"
        }
        if message.citations.isEmpty {
            return "这是 AI 生成的回复。"
        }
        return "回复下方有引用工作区，可以打开关联来源。"
    }

    private var reusablePromptText: String {
        if isUser {
            return message.content
        }

        let trimmed = message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(trimmed.prefix(700))
        return "基于这条回复继续解释：\n\n\(excerpt)"
    }

    private var citationCopyText: String {
        message.citations.enumerated().map { index, citation in
            let excerpt = citation.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if excerpt.isEmpty {
                return "\(index + 1). [\(citation.kind.rawValue)] \(citation.title)"
            }
            return "\(index + 1). [\(citation.kind.rawValue)] \(citation.title)\n\(excerpt)"
        }
        .joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.standard) {
            if !isUser {
                AssistantAvatar(isThinking: false)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: StudyDesign.Spacing.compact) {
                ChatMessageMetaRow(
                    title: isUser ? "你" : "学习助手",
                    timestamp: message.createdAt,
                    citationCount: isUser ? 0 : message.citations.count,
                    isTrailing: isUser
                )

                messageContent
                    .textSelection(.enabled)
                    .frame(maxWidth: isUser ? 540 : 760, alignment: isUser ? .trailing : .leading)
                    .modifier(ChatMessageContentChrome(isUser: isUser))
                    .accessibilityLabel(messageAccessibilityLabel)
                    .accessibilityHint(messageAccessibilityHint)

                if !isUser && !message.citations.isEmpty {
                    ChatCitationStrip(
                        citations: message.citations,
                        onOpenCitation: onOpenCitation
                    )
                }

                if let planDraft, !isUser {
                    switch planDraft.status {
                    case .pending:
                        AIPlanDraftConfirmationCard(
                            draft: planDraft,
                            onConfirm: {
                                onConfirmPlan(planDraft)
                            },
                            onEdit: {
                                onEditPlan(planDraft)
                            },
                            onDismiss: {
                                onDismissPlan(planDraft)
                            }
                        )
                    case .confirmed:
                        AIPlanDraftConfirmedCard(
                            draft: planDraft,
                            onOpenReviews: onOpenReviews
                        )
                    case .dismissed:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if isUser {
                Image(systemName: "person.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(StudyDesign.Colors.dataBackground))
                    .overlay(
                        Circle()
                            .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                    )
                    .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
                    .frame(width: 32, height: 32)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : (isUser ? 0 : 8))
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion || isUser {
                hasAppeared = true
            } else {
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    hasAppeared = true
                }
            }
        }
        .contextMenu {
            Button {
                onCopyText(message.content, "消息")
            } label: {
                Label("复制消息", systemImage: "doc.on.doc")
            }

            if !message.citations.isEmpty {
                Button {
                    onCopyText(citationCopyText, "引用")
                } label: {
                    Label("复制引用", systemImage: "quote.bubble")
                }
            }

            Divider()

            Button {
                onReusePrompt(reusablePromptText)
            } label: {
                Label(isUser ? "重新编辑这条问题" : "基于这条继续问", systemImage: isUser ? "arrow.uturn.backward" : "arrowshape.turn.up.left")
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if isUser {
            Text(message.content)
                .font(.body)
        } else {
            ChatMarkdownContent(content: message.content)
        }
    }
}

private struct ChatMessageContentChrome: ViewModifier {
    let isUser: Bool

    func body(content: Content) -> some View {
        if isUser {
            content
                .padding(.horizontal, StudyDesign.Spacing.chatInner)
                .padding(.vertical, StudyDesign.Spacing.standard)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.chatBubble)
                            .fill(StudyDesign.Colors.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.chatBubble)
                        .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
                )
        } else {
            content
                .padding(.vertical, StudyDesign.Spacing.micro)
        }
    }
}

private struct ChatMessageMetaRow: View {
    let title: String
    let timestamp: Date
    let citationCount: Int
    let isTrailing: Bool

    private var timestampText: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    private var accessibilityText: String {
        if citationCount > 0 {
            return "\(title)，\(timestampText)，\(citationCount) 条引用"
        }
        return "\(title)，\(timestampText)"
    }

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            if isTrailing {
                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            Text(timestampText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)

            if citationCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "quote.bubble")
                        .font(.caption2.weight(.bold))
                    Text("\(citationCount)")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(StudyDesign.Colors.secondary)
                .padding(.horizontal, StudyDesign.Spacing.compact)
                .padding(.vertical, 2)
                .background(Capsule().fill(StudyDesign.Colors.dataBackground))
                .overlay(
                    Capsule()
                        .stroke(StudyDesign.Colors.secondary.opacity(0.18), lineWidth: 1)
                )
            }

            if !isTrailing {
                Spacer(minLength: StudyDesign.Spacing.tight)
            }
        }
        .frame(maxWidth: isTrailing ? 540 : 760, alignment: isTrailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
}

private struct ChatMarkdownContent: View {
    let content: String

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownParser.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            ForEach(blocks) { block in
                ChatMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

private struct ChatMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ChatMarkdownListItem])
        case quote(String)
        case code(String)
        case callout(title: String, lines: [String], style: ChatMarkdownCalloutStyle)
    }

    let id: Int
    let kind: Kind
}

private struct ChatMarkdownListItem: Identifiable {
    let id: Int
    let marker: String
    let text: String
}

private enum ChatMarkdownCalloutStyle {
    case conclusion
    case steps
    case advice
    case context
    case note

    var icon: String {
        switch self {
        case .conclusion: return "checkmark.seal.fill"
        case .steps: return "list.number"
        case .advice: return "lightbulb.fill"
        case .context: return "doc.text.magnifyingglass"
        case .note: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .conclusion: return StudyDesign.Colors.success
        case .steps: return StudyDesign.Colors.info
        case .advice: return StudyDesign.Colors.secondary
        case .context: return StudyDesign.Colors.info
        case .note: return StudyDesign.Colors.warning
        }
    }
}

private struct ChatMarkdownBlockView: View {
    let block: ChatMarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            MarkdownInlineText(text)
                .font(level <= 1 ? .headline.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .padding(.top, level <= 1 ? StudyDesign.Spacing.micro : 0)

        case .paragraph(let text):
            MarkdownInlineText(text)
                .font(.callout)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineSpacing(3)

        case .list(let items):
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                ForEach(items) { item in
                    ChatMarkdownListRow(item: item)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(StudyDesign.Colors.accentHairline)
                    .frame(width: 3)

                MarkdownInlineText(text)
                    .font(.callout)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineSpacing(3)
            }
            .padding(StudyDesign.Spacing.tight)
            .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .textSelection(.enabled)
                    .padding(StudyDesign.Spacing.tight)
            }
            .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )

        case .callout(let title, let lines, let style):
            ChatMarkdownCallout(title: title, lines: lines, style: style)
        }
    }
}

private struct ChatMarkdownCallout: View {
    let title: String
    let lines: [String]
    let style: ChatMarkdownCalloutStyle

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: style.icon)
            }
            .foregroundStyle(style.tint)

            if lines.isEmpty {
                Text("暂无补充内容")
                    .font(.callout)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        ChatMarkdownLine(line: line, tint: style.tint)
                    }
                }
            }
        }
        .padding(StudyDesign.Spacing.standard)
        .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(style.tint.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct ChatMarkdownLine: View {
    let line: String
    let tint: Color

    var body: some View {
        if let item = ChatMarkdownParser.parseListItem(line, id: 0) {
            ChatMarkdownListRow(item: item, tint: tint)
        } else {
            MarkdownInlineText(line)
                .font(.callout)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineSpacing(3)
        }
    }
}

private struct ChatMarkdownListRow: View {
    let item: ChatMarkdownListItem
    var tint: Color = StudyDesign.Colors.labelSecondary

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Text(item.marker)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(StudyDesign.Colors.inputBackground))
                .overlay(Circle().stroke(StudyDesign.Colors.accentHairline.opacity(0.55), lineWidth: 1))

            MarkdownInlineText(item.text)
                .font(.callout)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownInlineText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    private var attributedText: AttributedString? {
        try? AttributedString(markdown: text)
    }

    var body: some View {
        if let attributedText {
            Text(attributedText)
        } else {
            Text(text)
        }
    }
}

private enum ChatMarkdownParser {
    static func parse(_ content: String) -> [ChatMarkdownBlock] {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [ChatMarkdownBlock] = []
        var index = 0

        func append(_ kind: ChatMarkdownBlock.Kind) {
            blocks.append(ChatMarkdownBlock(id: blocks.count, kind: kind))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(codeLine)
                    index += 1
                }
                append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let section = parseSectionHeader(trimmed) {
                index += 1
                var sectionLines: [String] = []
                if let inlineBody = section.inlineBody {
                    sectionLines.append(inlineBody)
                }

                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if next.isEmpty {
                        index += 1
                        if !sectionLines.isEmpty { break }
                        continue
                    }
                    if next.hasPrefix("```") || next.hasPrefix(">") || parseHeading(next) != nil || parseSectionHeader(next) != nil {
                        break
                    }
                    sectionLines.append(next)
                    index += 1
                }

                append(.callout(title: section.title, lines: sectionLines, style: section.style))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard next.hasPrefix(">") else { break }
                    quoteLines.append(next.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
                    index += 1
                }
                append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let firstItem = parseListItem(trimmed, id: 0) {
                var items = [firstItem]
                index += 1

                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if next.isEmpty { break }
                    guard let item = parseListItem(next, id: items.count) else { break }
                    items.append(item)
                    index += 1
                }

                append(.list(items))
                continue
            }

            var paragraphLines = [trimmed]
            index += 1

            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.isEmpty {
                    index += 1
                    break
                }
                if next.hasPrefix("```") || next.hasPrefix(">") || parseHeading(next) != nil || parseSectionHeader(next) != nil || parseListItem(next, id: 0) != nil {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }

            append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        if blocks.isEmpty {
            append(.paragraph(content))
        }

        return blocks
    }

    static func parseListItem(_ line: String, id: Int) -> ChatMarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return ChatMarkdownListItem(id: id, marker: "•", text: String(trimmed.dropFirst(2)).trimmedForChatMarkdown)
        }
        if trimmed.hasPrefix("• ") {
            return ChatMarkdownListItem(id: id, marker: "•", text: String(trimmed.dropFirst(2)).trimmedForChatMarkdown)
        }

        var digitPrefix = ""
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
            digitPrefix.append(trimmed[cursor])
            cursor = trimmed.index(after: cursor)
        }

        guard !digitPrefix.isEmpty, cursor < trimmed.endIndex else { return nil }
        let separator = trimmed[cursor]
        guard separator == "." || separator == "、" else { return nil }

        let textStart = trimmed.index(after: cursor)
        let itemText = String(trimmed[textStart...]).trimmedForChatMarkdown
        guard !itemText.isEmpty else { return nil }
        return ChatMarkdownListItem(id: id, marker: digitPrefix, text: itemText)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "#" {
            level += 1
            cursor = line.index(after: cursor)
        }

        guard (1...4).contains(level), cursor < line.endIndex, line[cursor] == " " else {
            return nil
        }

        let textStart = line.index(after: cursor)
        let text = String(line[textStart...]).trimmedForChatMarkdown
        return text.isEmpty ? nil : (level, text)
    }

    private static func parseSectionHeader(_ line: String) -> (title: String, inlineBody: String?, style: ChatMarkdownCalloutStyle)? {
        let normalized = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmedForChatMarkdown

        guard let colonIndex = normalized.firstIndex(where: { $0 == "：" || $0 == ":" }) else {
            return nil
        }

        let title = String(normalized[..<colonIndex]).trimmedForChatMarkdown
        guard !title.isEmpty, title.count <= 18, let style = calloutStyle(for: title) else {
            return nil
        }

        let bodyStart = normalized.index(after: colonIndex)
        let body = String(normalized[bodyStart...]).trimmedForChatMarkdown
        return (title, body.isEmpty ? nil : body, style)
    }

    private static func calloutStyle(for title: String) -> ChatMarkdownCalloutStyle? {
        if title.contains("结论") || title.contains("核心") {
            return .conclusion
        }
        if title.contains("步骤") || title.contains("解释") || title.contains("思路") || title.contains("拆解") {
            return .steps
        }
        if title.contains("建议") || title.contains("复习") || title.contains("下一步") || title.contains("类似题") {
            return .advice
        }
        if title.contains("结合") || title.contains("资料") || title.contains("依据") || title.contains("背景") {
            return .context
        }
        if title.contains("提醒") || title.contains("注意") || title.contains("风险") {
            return .note
        }
        return nil
    }
}

private extension String {
    var trimmedForChatMarkdown: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AIPlanDraftConfirmationCard: View {
    @State private var isShowingDismissConfirmation = false
    let draft: AIPlanDraft
    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onDismiss: () -> Void

    private var previewTasks: [DraftReviewItem] {
        Array(draft.reviewItems.prefix(3))
    }

    private var countsText: String {
        "\(draft.knowledgePoints.count) 个知识点 · \(draft.reviewItems.count) 个任务 · \(draft.mistakes.count) 个错题"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: "calendar.badge.plus")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: StudyDesign.Radius.small).fill(StudyDesign.Colors.warning.opacity(0.10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(StudyDesign.Colors.warning.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("AI 复习规划草稿")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.warning)
                    Text(draft.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(2)

                    Text(countsText)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                HStack(spacing: 4) {
                    Circle()
                        .fill(StudyDesign.Colors.warning)
                        .frame(width: 5, height: 5)
                    Text("待确认")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(StudyDesign.Colors.warning)
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, 5)
                .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                .overlay(Capsule().stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1))
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                AIPlanDraftMiniStat(title: "知识点", value: "\(draft.knowledgePoints.count)", icon: "lightbulb.fill", tint: StudyDesign.Colors.secondary)
                AIPlanDraftMiniStat(title: "任务", value: "\(draft.reviewItems.count)", icon: "checklist", tint: StudyDesign.Colors.secondary)
                AIPlanDraftMiniStat(title: "错题", value: "\(draft.mistakes.count)", icon: "xmark.circle.fill", tint: StudyDesign.Colors.danger)
            }

            Text(draft.summary)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(3)

            if !previewTasks.isEmpty {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(previewTasks) { item in
                        HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.compact) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(StudyDesign.Colors.secondary)
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                                .lineLimit(1)
                            if item.relatedMistakeTitle != nil {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(StudyDesign.Colors.danger)
                            }
                            Spacer(minLength: StudyDesign.Spacing.tight)
                            Text(item.dueInDays == 0 ? "今天" : "\(item.dueInDays) 天后")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                        .padding(.horizontal, StudyDesign.Spacing.tight)
                        .padding(.vertical, StudyDesign.Spacing.compact)
                        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
                        )
                    }
                }
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                Text("可加入复习规划")
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)

                Spacer()

                Button {
                    isShowingDismissConfirmation = true
                } label: {
                    Label("忽略", systemImage: "xmark")
                }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))
                    .help("忽略这份 AI 规划草稿")

                Button(action: onEdit) {
                    Label("编辑", systemImage: "slider.horizontal.3")
                }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .secondary, size: .compact))
                    .help("查看并编辑这份 AI 规划")

                Button(action: onConfirm) {
                    Label("加入", systemImage: "checkmark.circle.fill")
                }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
                    .help("确认这份 AI 规划")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.warning.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.warning)
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .shadow(color: StudyDesign.Shadow.elevated.color, radius: StudyDesign.Shadow.elevated.radius, y: StudyDesign.Shadow.elevated.y)
        .contextMenu {
            Button(action: onConfirm) {
                Label("加入复习规划", systemImage: "checkmark.circle.fill")
            }

            Button(action: onEdit) {
                Label("编辑规划", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                isShowingDismissConfirmation = true
            } label: {
                Label("忽略规划", systemImage: "xmark.circle")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 生成的复习规划，\(countsText)")
        .confirmationDialog("忽略这份 AI 规划？", isPresented: $isShowingDismissConfirmation, titleVisibility: .visible) {
            Button("忽略规划", role: .destructive) {
                onDismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("忽略后，这份规划不会写入复习队列。")
        }
    }
}

private struct AIPlanDraftMiniStat: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(StudyDesign.Colors.cardBackground))

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct ChatCitationStrip: View {
    let citations: [ChatMessageCitation]
    let onOpenCitation: (ChatMessageCitation) -> Void

    private var visibleCitations: [ChatMessageCitation] {
        Array(citations.prefix(8))
    }

    private var stripHint: String {
        citations.count > visibleCitations.count
            ? "横向浏览前 \(visibleCitations.count) 条引用，点击任一引用打开来源。"
            : "横向浏览引用，点击任一引用打开来源。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.compact) {
                Label("引用工作区", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("\(citations.count) 条")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.secondary)
                    .padding(.horizontal, StudyDesign.Spacing.compact)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                Text("点击打开来源")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach(visibleCitations) { citation in
                        Button {
                            onOpenCitation(citation)
                        } label: {
                            ChatCitationCard(citation: citation)
                        }
                        .buttonStyle(.plain)
                        .help("打开\(citation.kind.rawValue)：\(citation.title)")
                        .accessibilityLabel("\(citation.kind.rawValue)：\(citation.title)")
                        .accessibilityHint("打开第 \(citation.promptIndex) 个引用来源。")
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(StudyDesign.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.secondary.opacity(0.78))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.tight)
        }
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.52), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("引用工作区，\(citations.count) 条来源")
        .accessibilityHint(stripHint)
    }
}

private struct ChatCitationCard: View {
    let citation: ChatMessageCitation

    private var icon: String {
        switch citation.kind {
        case .document: return "doc.text"
        case .mistake: return "xmark.circle.fill"
        case .knowledge: return "lightbulb.fill"
        case .reviewTask: return "calendar.badge.clock"
        case .goal: return "target"
        }
    }

    private var tint: Color {
        switch citation.kind {
        case .document: return StudyDesign.Colors.secondary
        case .mistake: return StudyDesign.Colors.danger
        case .knowledge: return StudyDesign.Colors.secondary
        case .reviewTask: return StudyDesign.Colors.warning
        case .goal: return StudyDesign.Colors.success
        }
    }

    private var excerptText: String {
        citation.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accessibilityText: String {
        if excerptText.isEmpty {
            return "\(citation.kind.rawValue)，\(citation.title)，引用 \(citation.promptIndex)"
        }
        return "\(citation.kind.rawValue)，\(citation.title)，\(excerptText)，引用 \(citation.promptIndex)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(StudyDesign.Colors.inputBackground))
                Text(citation.kind.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: StudyDesign.Spacing.compact)
                Text("#\(citation.promptIndex)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }

            Text(citation.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(2)

            if !excerptText.isEmpty {
                Text(excerptText)
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 224, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(RoundedRectangle(cornerRadius: StudyDesign.Radius.small).fill(StudyDesign.Colors.inputBackground))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(tint.opacity(0.72))
                .frame(width: 2)
                .padding(.vertical, StudyDesign.Spacing.tight)
        }
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.42), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
}

private struct AIPlanDraftConfirmedCard: View {
    let draft: AIPlanDraft
    let onOpenReviews: () -> Void

    private var createdTaskCount: Int {
        draft.createdReviewTaskIDs.count
    }

    private var statusText: String {
        "已加入复习计划 · 新增 \(createdTaskCount) 个任务"
    }

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.success)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(draft.title)
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button(action: onOpenReviews) {
                Label("去复习计划", systemImage: "arrow.right")
            }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.success, prominence: .soft, size: .compact))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.standard)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.success)
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.tight)
        }
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .accessibilityElement(children: .contain)
    }
}

struct AIPlanDraftEditSheet: View {
    private enum OverviewFocus: Hashable {
        case title
        case summary
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIPlanDraft
    @State private var isShowingDismissConfirmation = false
    @State private var isShowingDiscardConfirmation = false
    @FocusState private var overviewFocus: OverviewFocus?
    private let originalDraft: AIPlanDraft
    let onSave: (AIPlanDraft) -> Void
    let onConfirm: (AIPlanDraft) -> Void
    let onDismissDraft: (AIPlanDraft) -> Void

    init(
        draft: AIPlanDraft,
        onSave: @escaping (AIPlanDraft) -> Void,
        onConfirm: @escaping (AIPlanDraft) -> Void,
        onDismissDraft: @escaping (AIPlanDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.originalDraft = draft
        self.onSave = onSave
        self.onConfirm = onConfirm
        self.onDismissDraft = onDismissDraft
    }

    private var knowledgeTitles: [String] {
        let pointTitles = draft.knowledgePoints
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let relatedTitles = draft.reviewItems
            .compactMap { $0.relatedKnowledgeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(pointTitles + relatedTitles)).sorted()
    }

    private var mistakeTitles: [String] {
        let mistakeTitles = draft.mistakes
            .map { $0.question.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let relatedTitles = draft.reviewItems
            .compactMap { $0.relatedMistakeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(mistakeTitles + relatedTitles)).sorted()
    }

    private var canSave: Bool {
        validationMessage == nil
    }

    private var saveHelpText: String {
        validationMessage ?? "保存当前 AI 规划"
    }

    private var confirmHelpText: String {
        validationMessage ?? "保存并加入复习队列"
    }

    private var validationMessage: String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "规划标题不能为空"
        }
        if draft.reviewItems.isEmpty {
            return "至少保留一个复习任务"
        }
        if let emptyIndex = draft.reviewItems.firstIndex(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "第 \(emptyIndex + 1) 个复习任务需要标题"
        }
        return nil
    }

    private var hasUnsavedChanges: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines) != originalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            || draft.summary.trimmingCharacters(in: .whitespacesAndNewlines) != originalDraft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            || reviewItemsChanged
    }

    private var reviewItemsChanged: Bool {
        guard draft.reviewItems.count == originalDraft.reviewItems.count else { return true }
        return zip(draft.reviewItems, originalDraft.reviewItems).contains { current, original in
            current.id != original.id
                || current.title.trimmingCharacters(in: .whitespacesAndNewlines) != original.title.trimmingCharacters(in: .whitespacesAndNewlines)
                || current.dueInDays != original.dueInDays
                || current.priority != original.priority
                || normalizedRelatedTitle(current.relatedKnowledgeTitle) != normalizedRelatedTitle(original.relatedKnowledgeTitle)
                || normalizedRelatedTitle(current.relatedMistakeTitle) != normalizedRelatedTitle(original.relatedMistakeTitle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            header
            editorContent
            actionsBar
        }
        .padding(StudyDesign.Spacing.roomy)
        .background(StudyDesign.Gradients.pageBackdrop)
        .confirmationDialog("忽略这份 AI 规划？", isPresented: $isShowingDismissConfirmation, titleVisibility: .visible) {
            Button("忽略规划", role: .destructive) {
                onDismissDraft(draft)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("忽略后，这份规划不会写入复习队列。")
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("当前 AI 规划还有未保存的修改。")
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(minWidth: 680, minHeight: 600)
#endif
    }

    private var highPriorityCount: Int {
        draft.reviewItems.filter { ($0.priority ?? 0) >= 4 }.count
    }

    private var linkedItemCount: Int {
        draft.reviewItems.filter { item in
            item.relatedKnowledgeTitle?.isEmpty == false || item.relatedMistakeTitle?.isEmpty == false
        }.count
    }

    private var soonestDueText: String {
        guard let days = draft.reviewItems.map(\.dueInDays).min() else { return "无任务" }
        return days == 0 ? "今天" : "\(days) 天后"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.warning).opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
                        )
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.warning)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("编辑 AI 规划")
                        .font(.title2.weight(.semibold))
                    Text("检查标题、节奏和关联资料后再加入复习队列")
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer(minLength: StudyDesign.Spacing.standard)
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                AIPlanDraftHeaderStat(title: "复习任务", value: "\(draft.reviewItems.count)", icon: "checklist", tint: StudyDesign.Colors.warning)
                AIPlanDraftHeaderStat(title: "最早到期", value: soonestDueText, icon: "clock", tint: StudyDesign.Colors.warning)
                AIPlanDraftHeaderStat(title: "已关联", value: "\(linkedItemCount)", icon: "link")
                AIPlanDraftHeaderStat(title: "高优先级", value: "\(highPriorityCount)", icon: "exclamationmark.circle", tint: StudyDesign.Colors.warning)
            }
        }
        .padding(StudyDesign.Spacing.roomy)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.warning.opacity(0.66))
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }

    @ViewBuilder
    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                overviewPanel
                reviewTasksPanel
            }
            .padding(.bottom, StudyDesign.Spacing.compact)
        }
        .scrollIndicators(.hidden)
    }

    private var overviewPanel: some View {
        AIPlanDraftPanel(
            title: "规划概览",
            subtitle: "让 AI 的建议变成可执行的学习安排",
            icon: "doc.text.magnifyingglass"
        ) {
            VStack(spacing: StudyDesign.Spacing.standard) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("标题")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    TextField("规划标题", text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                        .focused($overviewFocus, equals: .title)
                        .padding(StudyDesign.Spacing.normal)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .fill(StudyDesign.Colors.inputBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .stroke(
                                    overviewFocus == .title ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                                    lineWidth: overviewFocus == .title ? 2 : 1
                                )
                        )
                        .accessibilityLabel("规划标题")
                        .accessibilityHint("输入这份学习规划的标题")
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("摘要")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    TextField("规划摘要", text: $draft.summary, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...7)
                        .focused($overviewFocus, equals: .summary)
                        .padding(StudyDesign.Spacing.normal)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .fill(StudyDesign.Colors.inputBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .stroke(
                                    overviewFocus == .summary ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                                    lineWidth: overviewFocus == .summary ? 2 : 1
                                )
                        )
                        .accessibilityLabel("规划摘要")
                        .accessibilityHint("概括这份学习规划的目标与范围")
                }
            }
        }
    }

    private var reviewTasksPanel: some View {
        AIPlanDraftPanel(
            title: "复习任务",
            subtitle: "调整每个任务的到期日、优先级和资料关联",
            icon: "calendar.badge.clock",
            tint: StudyDesign.Colors.warning
        ) {
            if draft.reviewItems.isEmpty {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    Text("暂无复习任务。")
                        .font(.callout)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    addReviewTaskButton
                }
                .padding(StudyDesign.Spacing.normal)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .fill(StudyDesign.Colors.inputBackground)
                )
            } else {
                VStack(spacing: StudyDesign.Spacing.standard) {
                    ForEach($draft.reviewItems) { $item in
                        AIPlanDraftTaskEditCard(
                            item: $item,
                            knowledgeTitles: knowledgeTitles,
                            mistakeTitles: mistakeTitles,
                            onDelete: {
                                draft.reviewItems.removeAll { $0.id == item.id }
                            }
                        )
                    }

                    addReviewTaskButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var addReviewTaskButton: some View {
        Button {
            addReviewTask()
        } label: {
            Label("新增任务", systemImage: "plus.circle.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .secondary, size: .compact, minWidth: 98))
        .accessibilityLabel("新增复习任务")
        .help("在这份 AI 规划中添加一个复习任务")
    }

    @ViewBuilder
    private var actionsBar: some View {
#if os(iOS)
        VStack(spacing: StudyDesign.Spacing.tight) {
            if let validationMessage {
                AIPlanDraftValidationHint(message: validationMessage)
            }

            Button {
                normalizeDraft()
                onConfirm(draft)
            } label: {
                StudyActionPillLabel(title: "保存并确定加入", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary))
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
            .help(confirmHelpText)
            .accessibilityHint(confirmHelpText)

            HStack(spacing: StudyDesign.Spacing.tight) {
                Button(role: .destructive) {
                    isShowingDismissConfirmation = true
                } label: {
                    Label("忽略", systemImage: "xmark")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))

                Spacer()

                Button("取消") {
                    cancelEditing()
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact))
                .keyboardShortcut(.cancelAction)

                Button {
                    normalizeDraft()
                    onSave(draft)
                } label: {
                    Label("保存", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact))
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
                .help(saveHelpText)
                .accessibilityHint(saveHelpText)
            }
            .font(.callout.weight(.semibold))
        }
        .padding(.top, StudyDesign.Spacing.compact)
#else
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            if let validationMessage {
                AIPlanDraftValidationHint(message: validationMessage)
            }

            HStack {
                Button(role: .destructive) {
                    isShowingDismissConfirmation = true
                } label: {
                    Label("忽略草稿", systemImage: "xmark")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))

                Button("取消") {
                    cancelEditing()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    normalizeDraft()
                    onSave(draft)
                } label: {
                    Label("保存", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact))
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
                .help(saveHelpText)
                .accessibilityHint(saveHelpText)

                Button {
                    normalizeDraft()
                    onConfirm(draft)
                } label: {
                    Label("保存并确定加入", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .help(confirmHelpText)
                .accessibilityHint(confirmHelpText)
            }
        }
#endif
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func normalizeDraft() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.reviewItems = draft.reviewItems.map { item in
            DraftReviewItem(
                id: item.id,
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                dueInDays: min(max(item.dueInDays, 0), 365),
                priority: item.priority.map { min(max($0, 0), 5) },
                relatedKnowledgeTitle: normalizedRelatedTitle(item.relatedKnowledgeTitle),
                relatedMistakeTitle: normalizedRelatedTitle(item.relatedMistakeTitle),
                relatedMistakeID: relatedMistakeID(for: item.relatedMistakeTitle)
            )
        }
    }

    private func addReviewTask() {
        let taskNumber = draft.reviewItems.count + 1
        let dueInDays = draft.reviewItems.map(\.dueInDays).max().map { min($0 + 1, 365) } ?? 0
        let newTask = DraftReviewItem(
            title: "新增复习任务 \(taskNumber)",
            dueInDays: dueInDays,
            priority: 3
        )

        withAnimation(StudyDesign.Motion.animation(.normal)) {
            draft.reviewItems.append(newTask)
        }
    }

    private func normalizedRelatedTitle(_ title: String?) -> String? {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private func relatedMistakeID(for title: String?) -> UUID? {
        guard let title = normalizedRelatedTitle(title) else { return nil }
        let normalizedTitle = normalizedReference(title)
        return draft.mistakes.first { mistake in
            let normalizedQuestion = normalizedReference(mistake.question)
            return normalizedQuestion == normalizedTitle
                || normalizedQuestion.contains(normalizedTitle)
                || normalizedTitle.contains(normalizedQuestion)
        }?.id
    }

    private func normalizedReference(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}

private struct AIPlanDraftHeaderStat: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(StudyDesign.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
    }
}

private struct AIPlanDraftValidationHint: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct AIPlanDraftPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .fill(StudyDesign.Colors.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                                    .stroke(tint.opacity(0.16), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }

            content
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(StudyDesign.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct AIPlanDraftTaskEditCard: View {
    @Binding var item: DraftReviewItem
    let knowledgeTitles: [String]
    let mistakeTitles: [String]
    let onDelete: () -> Void
    @FocusState private var isTitleFocused: Bool

    private var dueDaysBinding: Binding<Int> {
        Binding(
            get: { item.dueInDays },
            set: { item.dueInDays = min(max($0, 0), 365) }
        )
    }

    private var priorityBinding: Binding<Int> {
        Binding(
            get: { item.priority ?? 3 },
            set: { item.priority = min(max($0, 0), 5) }
        )
    }

    private var relatedKnowledgeBinding: Binding<String> {
        Binding(
            get: { item.relatedKnowledgeTitle ?? "" },
            set: { item.relatedKnowledgeTitle = $0.isEmpty ? nil : $0 }
        )
    }

    private var relatedMistakeBinding: Binding<String> {
        Binding(
            get: { item.relatedMistakeTitle ?? "" },
            set: {
                item.relatedMistakeTitle = $0.isEmpty ? nil : $0
                item.relatedMistakeID = nil
            }
        )
    }

    private var priorityTint: Color {
        (item.priority ?? 0) >= 4 ? StudyDesign.Colors.warning : StudyDesign.Colors.secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                TextField("任务标题", text: $item.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .lineLimit(1...3)
                    .focused($isTitleFocused)
                    .padding(StudyDesign.Spacing.tight)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .fill(StudyDesign.Colors.inputBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(
                                isTitleFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                                lineWidth: isTitleFocused ? 2 : 1
                            )
                    )
                    .accessibilityLabel("复习任务标题")
                    .accessibilityHint("输入这个复习任务的名称")

                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))
                .help("删除这个任务")
            }

            AIPlanTaskControls(
                dueInDays: dueDaysBinding,
                priority: priorityBinding,
                relatedKnowledge: relatedKnowledgeBinding,
                relatedMistake: relatedMistakeBinding,
                knowledgeTitles: knowledgeTitles,
                mistakeTitles: mistakeTitles,
                priorityTint: priorityTint
            )
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(StudyDesign.Colors.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
    }
}

private struct AIPlanTaskControls: View {
    private enum ControlFocus: Hashable {
        case dueDecrease
        case dueIncrease
        case priority(Int)
        case knowledge
        case mistake
    }

    @Binding var dueInDays: Int
    @Binding var priority: Int
    @Binding var relatedKnowledge: String
    @Binding var relatedMistake: String
    let knowledgeTitles: [String]
    let mistakeTitles: [String]
    let priorityTint: Color
    @FocusState private var focusedControl: ControlFocus?

    private var dueTitle: String {
        dueInDays == 0 ? "今天到期" : "\(dueInDays) 天后"
    }

    private var decreaseDueHelp: String {
        dueInDays == 0 ? "已经是今天到期，不能再提前。" : "将到期时间提前一天"
    }

    private var increaseDueHelp: String {
        dueInDays >= 365 ? "最多可以设置到 365 天后。" : "将到期时间推迟一天"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    dueControl
                    priorityControl
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    dueControl
                    priorityControl
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    relationMenu(
                        title: "知识点",
                        value: relatedKnowledge,
                        placeholder: "不关联知识点",
                        icon: "lightbulb.fill",
                        tint: StudyDesign.Colors.secondary,
                        options: knowledgeTitles,
                        binding: $relatedKnowledge,
                        focus: .knowledge
                    )
                    relationMenu(
                        title: "错题",
                        value: relatedMistake,
                        placeholder: "不关联错题",
                        icon: "xmark.circle.fill",
                        tint: StudyDesign.Colors.danger,
                        options: mistakeTitles,
                        binding: $relatedMistake,
                        focus: .mistake,
                        display: ReviewPlanner.shortTitle
                    )
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    relationMenu(
                        title: "知识点",
                        value: relatedKnowledge,
                        placeholder: "不关联知识点",
                        icon: "lightbulb.fill",
                        tint: StudyDesign.Colors.secondary,
                        options: knowledgeTitles,
                        binding: $relatedKnowledge,
                        focus: .knowledge
                    )
                    relationMenu(
                        title: "错题",
                        value: relatedMistake,
                        placeholder: "不关联错题",
                        icon: "xmark.circle.fill",
                        tint: StudyDesign.Colors.danger,
                        options: mistakeTitles,
                        binding: $relatedMistake,
                        focus: .mistake,
                        display: ReviewPlanner.shortTitle
                    )
                }
            }
        }
        .font(.caption)
    }

    private var dueControl: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Button {
                dueInDays = max(0, dueInDays - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .iOSTouchTarget()
                    .background(Circle().fill(StudyDesign.Colors.inputBackground))
                    .overlay(
                        Circle()
                            .stroke(focusedControl == .dueDecrease ? StudyDesign.Colors.primary : .clear, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .dueDecrease)
            .foregroundStyle(dueInDays == 0 ? StudyDesign.Colors.labelTertiary : StudyDesign.Colors.labelSecondary)
            .disabled(dueInDays == 0)
            .help(decreaseDueHelp)
            .accessibilityLabel("提前到期时间")
            .accessibilityHint(decreaseDueHelp)

            Label(dueTitle, systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(minWidth: 88)

            Button {
                dueInDays = min(365, dueInDays + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .iOSTouchTarget()
                    .background(Circle().fill(StudyDesign.Colors.inputBackground))
                    .overlay(
                        Circle()
                            .stroke(focusedControl == .dueIncrease ? StudyDesign.Colors.primary : .clear, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .dueIncrease)
            .foregroundStyle(dueInDays >= 365 ? StudyDesign.Colors.labelTertiary : StudyDesign.Colors.secondary)
            .disabled(dueInDays >= 365)
            .help(increaseDueHelp)
            .accessibilityLabel("推迟到期时间")
            .accessibilityHint(increaseDueHelp)
        }
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
    }

    private var priorityControl: some View {
        HStack(spacing: 4) {
            Text("优先级")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .padding(.leading, StudyDesign.Spacing.compact)

            ForEach(0...5, id: \.self) { level in
                Button {
                    priority = level
                } label: {
                    Text("\(level)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(priority == level ? .white : StudyDesign.Colors.labelSecondary)
                        .frame(width: 24, height: 24)
                        .iOSTouchTarget()
                        .background(
                            Circle()
                                .fill(priority == level ? StudyDesign.Colors.primary : StudyDesign.Colors.cardBackground)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    focusedControl == .priority(level) || priority == level
                                        ? StudyDesign.Colors.primary
                                        : StudyDesign.Colors.inputHairline,
                                    lineWidth: focusedControl == .priority(level) || priority == level ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .priority(level))
                .accessibilityLabel("优先级 \(level)")
                .accessibilityAddTraits(priority == level ? .isSelected : [])
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.inputBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
    }

    private func priorityColor(_ level: Int) -> Color {
        switch level {
        case 0...2: return StudyDesign.Colors.labelSecondary
        case 3: return StudyDesign.Colors.secondary
        case 4: return StudyDesign.Colors.warning
        default: return StudyDesign.Colors.danger
        }
    }

    private func relationMenu(
        title: String,
        value: String,
        placeholder: String,
        icon: String,
        tint: Color,
        options: [String],
        binding: Binding<String>,
        focus: ControlFocus,
        display: @escaping (String) -> String = { $0 }
    ) -> some View {
        Menu {
            Button(placeholder) {
                binding.wrappedValue = ""
            }
            ForEach(options, id: \.self) { option in
                Button(display(option)) {
                    binding.wrappedValue = option
                }
            }
        } label: {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    Text(value.isEmpty ? placeholder : display(value))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                Spacer(minLength: StudyDesign.Spacing.compact)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(
                        focusedControl == focus ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                        lineWidth: focusedControl == focus ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: focus)
        .help("调整\(title)：当前为 \(value.isEmpty ? placeholder : display(value))")
        .accessibilityLabel("\(title)：\(value.isEmpty ? placeholder : display(value))")
        .accessibilityHint("打开\(title)关联菜单。")
    }
}

private struct AssistantAvatar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    let isThinking: Bool

    var body: some View {
        ZStack {
            if isThinking {
                Circle()
                    .fill(StudyDesign.Colors.info.opacity(0.08))
                    .scaleEffect(isPulsing ? 1.42 : 0.9)
                    .opacity(isPulsing ? 0 : 0.38)
            }

            Circle()
                .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.info))
                .frame(width: 32, height: 32)
                .shadow(color: StudyDesign.Colors.info.opacity(isThinking ? 0.14 : 0.06), radius: isThinking ? 8 : 4, y: 2)

            Image(systemName: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.info)
        }
        .frame(width: 36, height: 36)
        .onAppear {
            guard isThinking, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.standard) {
            AssistantAvatar(isThinking: true)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text("学习助手正在思考")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.info)

                if reduceMotion {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(StudyDesign.Colors.info.opacity(0.58))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, StudyDesign.Spacing.chatInner)
                    .padding(.vertical, StudyDesign.Spacing.standard)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.chatBubble)
                            .fill(StudyDesign.Colors.inputBackground)
                    )
                } else {
                    TimelineView(.animation) { timeline in
                        HStack(spacing: StudyDesign.Spacing.compact) {
                            ForEach(0..<3, id: \.self) { index in
                                TypingDot(date: timeline.date, index: index)
                            }
                        }
                        .padding(.horizontal, StudyDesign.Spacing.chatInner)
                        .padding(.vertical, StudyDesign.Spacing.standard)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.chatBubble)
                                .fill(StudyDesign.Colors.inputBackground)
                        )
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct TypingDot: View {
    let date: Date
    let index: Int

    private var phase: Double {
        date.timeIntervalSinceReferenceDate * 3.2 + Double(index) * 0.7
    }

    var body: some View {
        Circle()
            .fill(StudyDesign.Colors.info.opacity(0.52))
            .frame(width: 7, height: 7)
            .scaleEffect(0.75 + 0.28 * (sin(phase) + 1) / 2)
            .opacity(0.45 + 0.45 * (sin(phase) + 1) / 2)
    }
}

private struct ChatInputDock: View {
    @State private var isShowingClearConfirmation = false
    @FocusState private var isTextInputFocused: Bool
    @Binding var text: String
    let canSend: Bool
    let isBusy: Bool
    let hasMessages: Bool
    let referenceCount: Int
    let includesPersonalContext: Bool
    let answerMode: AIAnswerMode
    let sendUnavailableMessage: String?
    let onSend: () -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    let onOpenSettings: () -> Void
    let onTogglePersonalContext: () -> Void

    private var referenceTitle: String {
        referenceCount == 0 ? "无候选资料" : "\(referenceCount) 条候选资料"
    }

    private var contextTitle: String {
        includesPersonalContext ? "个人资料" : "通用回答"
    }

    private var contextSummaryTitle: String {
        referenceCount == 0 ? contextTitle : "\(contextTitle) · \(referenceTitle)"
    }

    private var sendButtonHelp: String {
        if isBusy {
            return "取消当前 AI 请求"
        }
        if let sendUnavailableMessage {
            return sendUnavailableMessage
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "输入问题后发送"
        }
        return "发送问题"
    }

    var body: some View {
        VStack(spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        ChatInputContextBadge(title: answerMode.label, icon: "text.bubble")
                        ChatInputContextBadge(
                            title: includesPersonalContext ? "检索个人资料" : "不检索个人资料",
                            icon: includesPersonalContext ? "doc.text.magnifyingglass" : "person.crop.circle.badge.xmark"
                        )
                        ChatInputContextBadge(title: referenceTitle, icon: "quote.bubble")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("回答模式：\(answerMode.label)；\(contextTitle)；检索候选：\(referenceTitle)")

                Spacer(minLength: StudyDesign.Spacing.micro)

                Menu {
                    Label(referenceTitle, systemImage: "quote.bubble")
                    Button {
                        onTogglePersonalContext()
                    } label: {
                        Label(
                            includesPersonalContext ? "关闭个人资料检索" : "开启个人资料检索",
                            systemImage: includesPersonalContext ? "person.crop.circle.badge.xmark" : "doc.text.magnifyingglass"
                        )
                    }
                    .help(includesPersonalContext ? "回答时不再检索个人资料" : "回答时检索导入资料、错题和复习任务")
                    .accessibilityHint(includesPersonalContext ? "关闭后，AI 会使用通用回答模式。" : "开启后，AI 会结合你的资料回答。")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 30, height: 28)
                        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous))
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .help("回答上下文")
                .accessibilityLabel("回答上下文设置，\(contextSummaryTitle)")
                .accessibilityHint("打开菜单切换是否使用个人资料。")

                if hasMessages {
                    Button {
                        isShowingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .frame(width: 30, height: 28)
                            .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .iOSTouchTarget()
                    .help("清空对话")
                    .accessibilityLabel("清空所有聊天记录")
                    .accessibilityHint("会先要求确认，确认后删除本地聊天记录。")
                }
            }

            if let sendUnavailableMessage {
                ChatInputValidationHint(message: sendUnavailableMessage, action: onOpenSettings)
            }

            HStack(alignment: .bottom, spacing: StudyDesign.Spacing.tight) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .fill(text.isEmpty ? StudyDesign.Colors.inputBackground : StudyDesign.Colors.inputBackground)
                    Image(systemName: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(text.isEmpty ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.info)
                }
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.46), lineWidth: 1)
                )
                .padding(.bottom, 2)

#if os(macOS)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("向 AI 工作台提问，或粘贴一道题...")
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    ChatReturnTextView(text: $text, onSubmit: onSend)
                        .frame(minHeight: 30, maxHeight: 96)
                        .focused($isTextInputFocused)
                        .accessibilityLabel("问题输入框")
                        .accessibilityHint("输入问题后按回车发送。")
                }
#else
                TextField("向 AI 工作台提问，或粘贴一道题...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit {
                        onSend()
                    }
                    .focused($isTextInputFocused)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
                    .padding(.vertical, 8)
                    .accessibilityLabel("问题输入框")
                    .accessibilityHint("输入问题后发送给 AI 工作台。")
#endif

                Button(action: isBusy ? onCancel : onSend) {
                    Image(systemName: isBusy ? "xmark" : "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle((canSend || isBusy) ? .white : StudyDesign.Colors.labelSecondary)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(canSend || isBusy ? StudyDesign.Colors.primary : StudyDesign.Colors.surfaceFillDeep)
                        )
                        .overlay(
                            Circle()
                                .stroke((canSend || isBusy) ? .white.opacity(0.18) : StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .disabled(!canSend && !isBusy)
                .scaleEffect((canSend || isBusy) ? 1 : 0.96)
                .animation(StudyDesign.Motion.animation(.fast), value: canSend || isBusy)
                .help(sendButtonHelp)
                .accessibilityLabel(isBusy ? "取消当前 AI 请求" : "发送问题")
                .accessibilityHint(sendButtonHelp)
            }
            .padding(.leading, StudyDesign.Spacing.tight)
            .padding(.trailing, StudyDesign.Spacing.compact)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                    .stroke(isTextInputFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline, lineWidth: isTextInputFocused ? 2 : 1)
            )
            .shadow(color: isTextInputFocused ? StudyDesign.Colors.primary.opacity(0.14) : StudyDesign.Shadow.card.color.opacity(0.42), radius: isTextInputFocused ? 5 : 3, y: 1)
        }
        .padding(.horizontal, StudyDesign.Spacing.relaxed)
        .padding(.top, StudyDesign.Spacing.tight)
        .padding(.bottom, StudyDesign.Spacing.tight)
        .frame(maxWidth: StudyDesign.Layout.readingMaxWidth)
        .frame(maxWidth: .infinity)
        .background {
            StudyDesign.Colors.chromeBackground
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.46))
                .frame(height: 1)
        }
        .onChange(of: text) { previousValue, newValue in
            if previousValue.isEmpty && !newValue.isEmpty {
                isTextInputFocused = true
            }
        }
        .confirmationDialog("清空当前对话？", isPresented: $isShowingClearConfirmation, titleVisibility: .visible) {
            Button("清空聊天记录", role: .destructive) {
                onClear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后，本地聊天记录会被删除。")
        }
    }
}

private struct ChatInputContextBadge: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .frame(minHeight: 28)
            .background(StudyDesign.Colors.inputBackground, in: Capsule())
            .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
    }
}

private struct ChatInputValidationHint: View {
    let message: String
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                hintLabel
                Spacer(minLength: StudyDesign.Spacing.tight)
                settingsButton
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                hintLabel
                settingsButton
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            StudyDesign.Colors.inputBackground,
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }

    private var hintLabel: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settingsButton: some View {
        Button(action: action) {
            Label("去设置", systemImage: "gearshape")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .secondary, size: .compact, minWidth: 82))
        .accessibilityLabel("打开设置")
    }
}

struct RetrievedContextList: View {
    var items: [RetrievedStudyContext]

    private var accessibilityText: String {
        "本轮检索资料，\(items.count) 条"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            HStack(alignment: .firstTextBaseline) {
                Label("检索候选资料", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.info)
                    .padding(.horizontal, StudyDesign.Spacing.tight)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(StudyDesign.Colors.cardBackground))
                    .overlay(
                        Capsule()
                            .stroke(StudyDesign.Colors.info.opacity(0.18), lineWidth: 1)
                    )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach(items) { item in
                        ContextChip(item: item)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(StudyDesign.Spacing.standard)
        .background(
            StudyDesign.Colors.cardBackground,
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.info.opacity(0.56))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.standard)
        }
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.48), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("这些资料会作为本轮 AI 回复的参考上下文。")
    }
}

private struct ContextChip: View {
    let item: RetrievedStudyContext

    private var icon: String {
        switch item.kind {
        case .document: return "doc.text"
        case .mistake: return "xmark.circle.fill"
        case .knowledge: return "lightbulb.fill"
        case .reviewTask: return "calendar.badge.clock"
        case .goal: return "target"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .document: return StudyDesign.Colors.secondary
        case .mistake: return StudyDesign.Colors.danger
        case .knowledge: return StudyDesign.Colors.secondary
        case .reviewTask: return StudyDesign.Colors.warning
        case .goal: return StudyDesign.Colors.success
        }
    }

    private var accessibilityText: String {
        "\(item.kind.rawValue)：\(item.title)，相关度 \(item.score)。\(item.excerpt)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Label {
                Text(item.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: icon)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelPrimary)

            Text(item.excerpt)
                .font(.caption2)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(2)

            HStack(spacing: StudyDesign.Spacing.compact) {
                Text("相关度")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text("\(item.score)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 210, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(StudyDesign.Colors.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(tint.opacity(0.68))
                .frame(width: 2)
                .padding(.vertical, StudyDesign.Spacing.tight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("AI 会参考这条资料组织回答。")
    }
}

private struct ChatWorkbenchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                StudyDesign.Colors.pageBackground,
                StudyDesign.Colors.pageBackground,
                StudyDesign.Colors.pageBackground
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

#if os(macOS)
private struct ChatReturnTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ReturnSubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = {
            context.coordinator.submit()
        }
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func submit() {
            onSubmit()
        }
    }

    final class ReturnSubmittingTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let shouldSubmit = isReturn && modifiers.isDisjoint(with: [.shift, .option, .command, .control])

            if shouldSubmit {
                if hasMarkedText() {
                    super.keyDown(with: event)
                    return
                }

                onSubmit?()
                return
            }

            super.keyDown(with: event)
        }
    }
}
#endif
