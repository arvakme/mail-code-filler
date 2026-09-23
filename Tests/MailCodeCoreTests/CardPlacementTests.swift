import Foundation
import Testing

@testable import MailCodeCore

struct CardPlacementTests {
    @Test func defaultMousePlacementIsBelowRightAndKeepsCursorOutside() {
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let pointer = CGPoint(x: 500, y: 500)
        let frame = CardPlacement.followingMouse(
            cardSize: CGSize(width: 350, height: 220), pointer: pointer, visibleFrame: visible)

        #expect(frame.minX == pointer.x + CardPlacement.pointerGap)
        #expect(frame.maxY == pointer.y - CardPlacement.pointerGap)
        #expect(visible.contains(frame))
        #expect(!frame.contains(pointer))
    }

    @Test func mousePlacementClampsAtScreenEdgesWithoutCoveringPointer() {
        let visible = CGRect(x: 100, y: -100, width: 900, height: 650)
        let pointer = CGPoint(x: 995, y: -95)
        let frame = CardPlacement.followingMouse(
            cardSize: CGSize(width: 360, height: 240), pointer: pointer, visibleFrame: visible)

        #expect(visible.contains(frame))
        #expect(!frame.contains(pointer))
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.minY >= visible.minY)
    }

    @Test func mousePlacementLeavesTheTransparentWindowMarginOutsideThePointer() {
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let pointer = CGPoint(x: 500, y: 500)
        let transparentMargin: CGFloat = 24
        let frame = CardPlacement.followingMouse(
            cardSize: CGSize(width: 350, height: 220), pointer: pointer,
            visibleFrame: visible, gap: CardPlacement.pointerGap + transparentMargin,
            collisionMargin: transparentMargin)

        #expect(!frame.insetBy(dx: -transparentMargin, dy: -transparentMargin).contains(pointer))
    }

    @Test func mouseInTheMenuBarDoesNotFallUnderTheClampedWindowMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1_200, height: 780)
        let pointer = CGPoint(x: 500, y: 790)
        let margin: CGFloat = 24
        let frame = CardPlacement.followingMouse(
            cardSize: CGSize(width: 350, height: 220), pointer: pointer,
            visibleFrame: visible, gap: CardPlacement.pointerGap + margin, collisionMargin: margin)

        #expect(visible.contains(frame))
        #expect(!frame.insetBy(dx: -margin, dy: -margin).contains(pointer))
    }

    @Test func rememberedPositionRestoresPerScreenAndFallsBackWhenUnavailableOrOffscreen() {
        let first = CardPlacementScreen(
            identifier: "display-1", visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let second = CardPlacementScreen(
            identifier: "display-2", visibleFrame: CGRect(x: 1_000, y: -200, width: 800, height: 600))
        let savedFirst = CardPlacement.remember(
            frame: CGRect(x: 300, y: 140, width: 320, height: 200), on: first)
        let savedSecond = CardPlacement.remember(
            frame: CGRect(x: 1_080, y: -80, width: 320, height: 200), on: second)
        let screens = [first, second]
        let size = CGSize(width: 320, height: 200)

        #expect(
            CardPlacement.restoredFrame(
                positions: [savedFirst, savedSecond], for: "display-2", screens: screens, cardSize: size)
                == CGRect(x: 1_080, y: -80, width: 320, height: 200))
        #expect(
            CardPlacement.restoredFrame(
                positions: [savedFirst, savedSecond], for: "display-1", screens: screens, cardSize: size)
                == CGRect(x: 300, y: 140, width: 320, height: 200))
        #expect(
            CardPlacement.restoredFrame(
                positions: [savedFirst, savedSecond], for: "display-3", screens: screens, cardSize: size)
                == nil)

        let pointer = CGPoint(x: 1_500, y: 0)
        let fallback = CardPlacement.followingMouse(
            cardSize: size, pointer: pointer, visibleFrame: second.visibleFrame)
        #expect(
            CardPlacement.preferredFrame(
                mode: .followMouse,
                shouldUseRememberedPosition: true,
                rememberedPositions: [savedFirst],
                currentScreen: second,
                screens: [second],
                cardSize: size,
                pointer: pointer,
                inputAnchor: nil) == fallback)

        let offscreen = RememberedCardPosition(
            screenIdentifier: "display-2", xOffset: 750, yOffset: 500)
        #expect(
            CardPlacement.restoredFrame(
                positions: [offscreen], for: "display-2", screens: screens, cardSize: size) == nil)
        #expect(
            CardPlacement.preferredFrame(
                mode: .followMouse,
                shouldUseRememberedPosition: true,
                rememberedPositions: [offscreen],
                currentScreen: second,
                screens: screens,
                cardSize: size,
                pointer: pointer,
                inputAnchor: nil) == fallback)
        #expect(
            CardPlacement.preferredFrame(
                mode: .followMouse,
                shouldUseRememberedPosition: false,
                rememberedPositions: [savedSecond],
                currentScreen: second,
                screens: screens,
                cardSize: size,
                pointer: pointer,
                inputAnchor: nil) == fallback)
    }

    @Test func rememberedMousePlacementFallsBackWhenItWouldCoverThePointer() {
        let screen = CardPlacementScreen(
            identifier: "display-1", visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        let size = CGSize(width: 320, height: 200)
        let saved = CardPlacement.remember(
            frame: CGRect(x: 300, y: 140, width: size.width, height: size.height), on: screen)
        let pointer = CGPoint(x: 400, y: 200)
        let fallback = CardPlacement.followingMouse(
            cardSize: size, pointer: pointer, visibleFrame: screen.visibleFrame,
            gap: CardPlacement.pointerGap + 24, collisionMargin: 24)

        let result = CardPlacement.preferredFrame(
            mode: .followMouse,
            shouldUseRememberedPosition: true,
            rememberedPositions: [saved],
            currentScreen: screen,
            screens: [screen],
            cardSize: size,
            pointer: pointer,
            inputAnchor: nil,
            mouseGap: CardPlacement.pointerGap + 24,
            collisionMargin: 24)

        #expect(result == fallback)
        #expect(!result.insetBy(dx: -24, dy: -24).contains(pointer))
    }

    @Test func followingInputPlacementKeepsCaretFallbackAvailable() {
        let visible = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let caret = CGRect(x: 680, y: 10, width: 2, height: 20)
        let frame = CardPlacement.followingInput(
            cardSize: CGSize(width: 350, height: 220), anchor: caret, visibleFrame: visible)

        #expect(visible.contains(frame))
        #expect(frame.minY >= caret.maxY + CardPlacement.caretGap)
    }
}
