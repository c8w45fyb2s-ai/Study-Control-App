import SwiftUI

/// 娱乐规则与计时页面的可复用入口。
///
/// 首页快捷入口、“我的”入口和 macOS 侧栏都共享同一个 AppStore，
/// 页面只构造只读上下文，所有修改继续回到统一存储入口。
struct EntertainmentRulesPage: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let planningContext = store.snapshot.planningContext(now: Date())
        ScrollView(.vertical) {
            EntertainmentRulesView(
                context: store.snapshot.entertainmentContext(
                    context: planningContext,
                    notificationAuthorized: nil
                ),
                onSaveRule: { draft in
                    store.saveEntertainmentRule(
                        name: draft.name,
                        condition: draft.condition,
                        fallback: draft.fallback,
                        rewardMinutes: draft.rewardMinutes,
                        ruleID: draft.ruleID,
                        effectiveFrom: draft.effectiveFromValue,
                        effectiveUntil: draft.effectiveUntilValue,
                        repeatWeekdays: draft.repeatWeekdays,
                        targets: draft.targets,
                        isEnabled: draft.isEnabled
                    )
                },
                onDeleteRule: { id in
                    store.deleteEntertainmentRule(id: id)
                },
                onToggleRule: { id, isEnabled in
                    store.setEntertainmentRuleEnabled(id: id, isEnabled: isEnabled)
                },
                onRefresh: {
                    Task { _ = await store.performPlanAction(.refresh(dayKey: planningContext.todayKey)) }
                },
                onIntents: { intents in
                    Task { _ = await store.applyEntertainmentIntents(intents) }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
