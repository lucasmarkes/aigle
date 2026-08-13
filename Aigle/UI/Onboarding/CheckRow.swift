import SwiftUI

/// One permission, with the result of a real probe next to it. Nothing here is
/// read from a "we asked once" flag — the status came from trying the thing.
struct CheckRow: View {
    let check: SetupCheck
    var fixTitle: LocalizedStringKey?
    var fix: (() -> Void)?

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(status: check.status)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.title)
                        .font(.system(size: 13, weight: .medium))
                    if check.weight == .required {
                        Text("Required")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail = check.status.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(check.status.isFail ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(check.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let fix, let fixTitle, !check.status.isPass {
                Button(fixTitle, action: fix)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(
            settings.motionReduced ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3),
            value: check.status
        )
    }
}

/// The little dot that turns from a spinner into a verdict.
struct StatusBadge: View {
    let status: SetupCheck.Status

    var body: some View {
        Group {
            switch status {
            case .idle:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.tertiary)
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 15, height: 15)
            case .pass:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .fail:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16, height: 16)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: LocalizedStringKey {
        switch status {
        case .idle: "Not checked"
        case .checking: "Checking"
        case .pass: "Passed"
        case .warn: "Needs attention"
        case .fail: "Failed"
        }
    }
}

/// Shared heading for every step, so the rhythm stays the same as you move.
struct StepHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 22, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}
