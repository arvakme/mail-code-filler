import Foundation

public enum CardPlacementMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case followMouse
    case followInputCaret
}

public struct CardPlacementScreen: Equatable, Sendable {
    public let identifier: String
    public let visibleFrame: CGRect

    public init(identifier: String, visibleFrame: CGRect) {
        self.identifier = identifier
        self.visibleFrame = visibleFrame
    }
}

/// An origin offset from the display's visibleFrame, rather than global desktop coordinates.
public struct RememberedCardPosition: Codable, Equatable, Sendable {
    public let screenIdentifier: String
    public let xOffset: Double
    public let yOffset: Double

    public init(screenIdentifier: String, xOffset: Double, yOffset: Double) {
        self.screenIdentifier = screenIdentifier
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

public enum CardPlacement {
    public static let pointerGap: CGFloat = 16
    public static let caretGap: CGFloat = 8

    /// Positions the visible glass surface below-right of the pointer when it fits. Alternate sides
    /// are tried at screen edges so the cursor remains outside the card. Returned frames are clamped.
    public static func followingMouse(
        cardSize: CGSize, pointer: CGPoint, visibleFrame: CGRect,
        gap: CGFloat = pointerGap, collisionMargin: CGFloat = 0
    ) -> CGRect {
        let size = fittedSize(cardSize, in: visibleFrame)
        let positions = pointerOrigins(pointer: pointer, size: size, gap: gap)
        for origin in positions {
            let frame = clampedFrame(origin: origin, size: size, visibleFrame: visibleFrame)
            if !frame.insetBy(dx: -collisionMargin, dy: -collisionMargin).contains(pointer) {
                return frame
            }
        }

        // Extremely small displays may leave no collision-free placement at the requested size.
        // Shrink the dimension that preserves more of the card, then place it outside the pointer.
        let left = max(0, pointer.x - visibleFrame.minX - gap)
        let right = max(0, visibleFrame.maxX - pointer.x - gap)
        let below = max(0, pointer.y - visibleFrame.minY - gap)
        let above = max(0, visibleFrame.maxY - pointer.y - gap)
        let widthLimit = min(size.width, max(left, right))
        let heightLimit = min(size.height, max(below, above))
        var safeSize = size
        if size.width > 0, widthLimit / size.width >= (heightLimit / max(size.height, 1)) {
            safeSize.width = widthLimit
        } else {
            safeSize.height = heightLimit
        }
        for origin in pointerOrigins(pointer: pointer, size: safeSize, gap: gap) {
            let frame = clampedFrame(origin: origin, size: safeSize, visibleFrame: visibleFrame)
            if !frame.insetBy(dx: -collisionMargin, dy: -collisionMargin).contains(pointer) { return frame }
        }
        return clampedFrame(origin: positions[0], size: safeSize, visibleFrame: visibleFrame)
    }

    /// Preserves the existing caret/field behavior: prefer below the anchor, then above, clamped.
    public static func followingInput(
        cardSize: CGSize, anchor: CGRect, visibleFrame: CGRect, gap: CGFloat = caretGap
    ) -> CGRect {
        let size = fittedSize(cardSize, in: visibleFrame)
        let below = anchor.minY - size.height - gap
        let above = anchor.maxY + gap
        let proposedY = below >= visibleFrame.minY ? below : above
        let proposed = CGPoint(x: anchor.minX, y: proposedY)
        return clampedFrame(origin: proposed, size: size, visibleFrame: visibleFrame)
    }

    public static func clampedFrame(
        origin: CGPoint, size: CGSize, visibleFrame: CGRect
    ) -> CGRect {
        let fitted = fittedSize(size, in: visibleFrame)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - fitted.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - fitted.height)
        return CGRect(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY),
            width: fitted.width,
            height: fitted.height)
    }

    public static func remember(
        frame: CGRect, on screen: CardPlacementScreen
    ) -> RememberedCardPosition {
        RememberedCardPosition(
            screenIdentifier: screen.identifier,
            xOffset: Double(frame.minX - screen.visibleFrame.minX),
            yOffset: Double(frame.minY - screen.visibleFrame.minY))
    }

    /// Returns nil when the saved display is gone or the current card no longer fits there.
    public static func restoredFrame(
        positions: [RememberedCardPosition],
        for screenIdentifier: String,
        screens: [CardPlacementScreen],
        cardSize: CGSize
    ) -> CGRect? {
        guard let position = positions.first(where: { $0.screenIdentifier == screenIdentifier }),
            let screen = screens.first(where: { $0.identifier == screenIdentifier }),
            cardSize.width > 0, cardSize.height > 0,
            cardSize.width <= screen.visibleFrame.width,
            cardSize.height <= screen.visibleFrame.height
        else { return nil }

        let frame = CGRect(
            x: screen.visibleFrame.minX + position.xOffset,
            y: screen.visibleFrame.minY + position.yOffset,
            width: cardSize.width,
            height: cardSize.height)
        guard screen.visibleFrame.contains(frame) else { return nil }
        return frame
    }

    public static func preferredFrame(
        mode: CardPlacementMode,
        shouldUseRememberedPosition: Bool,
        rememberedPositions: [RememberedCardPosition],
        currentScreen: CardPlacementScreen,
        screens: [CardPlacementScreen],
        cardSize: CGSize,
        pointer: CGPoint,
        inputAnchor: CGRect?,
        mouseGap: CGFloat = pointerGap,
        collisionMargin: CGFloat = 0
    ) -> CGRect {
        if shouldUseRememberedPosition,
            let remembered = restoredFrame(
                positions: rememberedPositions,
                for: currentScreen.identifier,
                screens: screens,
                cardSize: cardSize),
            mode != .followMouse
                || !remembered.insetBy(dx: -collisionMargin, dy: -collisionMargin).contains(pointer)
        {
            return remembered
        }

        switch mode {
        case .followMouse:
            return followingMouse(
                cardSize: cardSize, pointer: pointer, visibleFrame: currentScreen.visibleFrame,
                gap: mouseGap, collisionMargin: collisionMargin)
        case .followInputCaret:
            let anchor = inputAnchor ?? CGRect(x: pointer.x, y: pointer.y, width: 1, height: 1)
            return followingInput(
                cardSize: cardSize, anchor: anchor, visibleFrame: currentScreen.visibleFrame)
        }
    }

    private static func fittedSize(_ size: CGSize, in visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(max(0, size.width), max(0, visibleFrame.width)),
            height: min(max(0, size.height), max(0, visibleFrame.height)))
    }

    private static func pointerOrigins(pointer: CGPoint, size: CGSize, gap: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: pointer.x + gap, y: pointer.y - size.height - gap),
            CGPoint(x: pointer.x - size.width - gap, y: pointer.y - size.height - gap),
            CGPoint(x: pointer.x + gap, y: pointer.y + gap),
            CGPoint(x: pointer.x - size.width - gap, y: pointer.y + gap),
            CGPoint(x: pointer.x + gap, y: pointer.y - size.height / 2),
            CGPoint(x: pointer.x - size.width - gap, y: pointer.y - size.height / 2),
            CGPoint(x: pointer.x - size.width / 2, y: pointer.y + gap),
            CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - gap),
        ]
    }
}
