enum ModifierEventState {
    static func configuredModifierIsDown(flags: UInt64, deviceMask: UInt64) -> Bool {
        flags & deviceMask != 0
    }

    static func canceledGestureEnded(
        familyFlagIsDown: Bool,
        changedKeyIsSameFamily: Bool
    ) -> Bool {
        changedKeyIsSameFamily && !familyFlagIsDown
    }

    static func isCorrectionGesture(
        optionIsDown: Bool,
        configuredModifierIsOption: Bool,
        correctionGesturesAllowed: Bool
    ) -> Bool {
        optionIsDown && !configuredModifierIsOption && correctionGesturesAllowed
    }
}
