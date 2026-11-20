import SwiftUI
import UIKit

extension Theme {
    /// System Paper is pure HIG: an inset-grouped `List` under a large title,
    /// with system semantic colors, SF Pro, and system motion (the
    /// critically damped spring `.smooth` uses) plus the stagger. The navy
    /// accent is the only brand color, used as the tint.
    /// Severity tints are the Mac panel's own (system orange and red).
    static var systemPaper: Theme {
        Theme(
            id: .systemPaper,
            displayName: "System Paper",
            ground: Color(uiColor: .systemGroupedBackground),
            surface: Color(uiColor: .secondarySystemGroupedBackground),
            ink: Color(uiColor: .label),
            inkSecondary: Color(uiColor: .secondaryLabel),
            accent: Color(light: 0x2C4896, dark: 0x7EA6EC),
            hairline: Color(uiColor: .separator),
            pillFill: Color(uiColor: .tertiarySystemFill),
            artTint: Color(uiColor: .secondaryLabel),
            warning: .orange,
            error: .red,
            titleFont: .largeTitle.bold(),
            sectionFont: .footnote,
            bodyFont: .body,
            metaFont: .subheadline.weight(.semibold),
            detailFont: .subheadline,
            timestampFont: .subheadline,
            pillFont: .subheadline.weight(.medium),
            emptyFont: .title3.weight(.semibold),
            chrome: .insetGrouped,
            margin: 20,
            rowPadding: 0,
            rowGap: 0,
            innerGap: 4,
            pillInsets: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12),
            cornerRadius: 10,
            pillCornerRadius: 999,
            borderWidth: 0,
            hardShadow: 0,
            symbolVariant: .none,
            symbolWeight: .regular,
            emptyArt: .groomGlyph(height: 128),
            entranceDuration: 0.3,
            entranceBounce: 0,
            entranceOffset: 6
        )
    }
}
