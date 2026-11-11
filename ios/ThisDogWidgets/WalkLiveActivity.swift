import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ThisDogWidgets: WidgetBundle {
    var body: some Widget {
        WalkLiveActivity()
        DigestWidget()
    }
}

private let accent = Color(red: 0xEE / 255, green: 0x6A / 255, blue: 0x24 / 255)

/// Die Runde auf dem Sperrbildschirm: groß die Zeit, daneben die Strecke.
struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    status(context.state)
                    clock(context.state, size: 44)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(km(context.state.meters)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("km").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        status(context.state)
                        clock(context.state, size: 30)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(km(context.state.meters)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("km").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                }
            } compactLeading: {
                clock(context.state, size: 14).foregroundStyle(accent)
            } compactTrailing: {
                Text(km(context.state.meters)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            } minimal: {
                Image(systemName: "pawprint").foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    private func status(_ s: WalkActivityAttributes.ContentState) -> some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 7, height: 7).opacity(s.runningSince == nil ? 0.35 : 1)
            Text(s.runningSince == nil ? String(localized: "Pause") : String(localized: "Unterwegs")).font(.caption.weight(.semibold)).foregroundStyle(accent)
        }
    }

    @ViewBuilder
    private func clock(_ s: WalkActivityAttributes.ContentState, size: CGFloat) -> some View {
        if let start = s.clockStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
        } else {
            Text(Duration.seconds(s.banked), format: .time(pattern: s.banked >= 3600 ? .hourMinuteSecond : .minuteSecond))
                .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }

    private func km(_ m: Double) -> String {
        (m / 1000).formatted(.number.precision(.fractionLength(2)).locale(AppLocale.current))
    }
}
