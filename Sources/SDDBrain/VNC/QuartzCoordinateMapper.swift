// QuartzCoordinateMapper.swift
// SDDBrain — maps between ShowUI-2B normalized coordinates,
// VNC physical pixel coordinates, and macOS logical point coordinates.
//
// Coordinate systems:
//   Normalized  — (0,0) top-left, (1,1) bottom-right (ShowUI-2B output)
//   Physical    — pixel coordinates matching the VNC framebuffer
//   Logical     — CGEvent / AppKit point space (may differ from physical
//                 on Retina displays due to scale factor)

import Foundation
import CoreGraphics
import AppKit

public struct QuartzCoordinateMapper: Sendable {

    // MARK: - Stored properties

    /// The CoreGraphics display this mapper targets.
    public let displayID: CGDirectDisplayID

    /// The logical point size of the display (from `CGDisplayBounds`).
    public let logicalSize: CGSize

    /// The physical pixel size of the display (from `CGDisplayPixelsWide/High`).
    public let physicalSize: CGSize

    /// Ratio of physical pixels to logical points (e.g. 2.0 on Retina).
    public let scaleFactor: CGFloat

    // MARK: - Init

    /// Creates a mapper for the specified display.
    /// - Parameter displayID: The CoreGraphics display ID. Defaults to the
    ///   main display (`CGMainDisplayID()`).
    public init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID

        let bounds = CGDisplayBounds(displayID)
        logicalSize = CGSize(width: bounds.width, height: bounds.height)

        let pxWide = CGDisplayPixelsWide(displayID)
        let pxHigh = CGDisplayPixelsHigh(displayID)
        physicalSize = CGSize(width: CGFloat(pxWide), height: CGFloat(pxHigh))

        // Derive scale factor; fall back to NSScreen.main if degenerate.
        if bounds.width > 0 {
            scaleFactor = CGFloat(pxWide) / bounds.width
        } else {
            scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        }
    }

    // MARK: - Coordinate conversions

    /// Converts a ShowUI-2B normalized point (0–1 in each axis) to logical
    /// points suitable for `CGEvent` / AppKit APIs.
    ///
    /// - Parameter normalized: A point where (0,0) is the top-left corner
    ///   and (1,1) is the bottom-right corner of the display.
    /// - Returns: The corresponding point in logical (CGEvent) space.
    public func normalizedToLogical(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: normalized.x * logicalSize.width,
            y: normalized.y * logicalSize.height
        )
    }

    /// Converts a ShowUI-2B normalized point (0–1) to physical pixel
    /// coordinates for use in a VNC `PointerEvent`.
    ///
    /// - Parameter normalized: A point where (0,0) is the top-left corner
    ///   and (1,1) is the bottom-right corner of the display.
    /// - Returns: The corresponding point in physical pixel space.
    public func normalizedToPhysical(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: normalized.x * physicalSize.width,
            y: normalized.y * physicalSize.height
        )
    }

    /// Converts physical pixel coordinates (VNC framebuffer) to logical points.
    ///
    /// - Parameter physical: A point in the VNC framebuffer's pixel space.
    /// - Returns: The corresponding point in macOS logical point space.
    public func physicalToLogical(_ physical: CGPoint) -> CGPoint {
        guard scaleFactor != 0 else { return physical }
        return CGPoint(
            x: physical.x / scaleFactor,
            y: physical.y / scaleFactor
        )
    }

    /// Converts logical points (CGEvent space) to physical pixel coordinates.
    ///
    /// - Parameter logical: A point in macOS logical point space.
    /// - Returns: The corresponding point in the VNC framebuffer's pixel space.
    public func logicalToPhysical(_ logical: CGPoint) -> CGPoint {
        CGPoint(
            x: logical.x * scaleFactor,
            y: logical.y * scaleFactor
        )
    }

    /// Clamps a point so it lies within the display bounds.
    ///
    /// - Parameters:
    ///   - point: The point to clamp.
    ///   - physical: Pass `true` if `point` is in physical pixel space,
    ///     `false` if it is in logical point space.
    /// - Returns: The clamped point in the same coordinate space as `point`.
    public func clampToDisplay(_ point: CGPoint, physical: Bool) -> CGPoint {
        let size = physical ? physicalSize : logicalSize
        return CGPoint(
            x: max(0, min(point.x, size.width - 1)),
            y: max(0, min(point.y, size.height - 1))
        )
    }
}
