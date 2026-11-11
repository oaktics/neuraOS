#if os(macOS) || os(iOS) || os(visionOS)
/// neuraOS: cumulative work counters of the Metal renderer. They exist so
/// tests and benchmarks can assert how much work a frame did, not how long
/// it took.
public struct MetalRenderStatistics: Equatable {
    /// Frames for which draw data was built.
    public var frames = 0
    /// Rows whose attributed string, shaping and vertex data were rebuilt.
    public var rowsRebuilt = 0
    /// Rows drawn from cached vertex data.
    public var rowsReused = 0
    /// Reused rows whose cached vertex data was moved to another screen row.
    public var rowsRepositioned = 0
    /// Glyph bitmaps rasterized with CoreText.
    public var glyphsRasterized = 0
    /// Text runs shaped with CoreText because they were not in the shaper cache.
    public var runsShaped = 0
    /// Reused rows that differed from a fresh rebuild. Only counted while
    /// `TerminalView.metalVerifiesRowReuse` is set; must stay zero.
    public var reuseMismatches = 0

    public init() {}
}
#endif
