import Foundation
import XCTest

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(Testing)
    import Testing
#endif

private struct GlobalState {
    var accessedSnapshotPaths: Set<URL>
    var diffTool: SnapshotTestingConfiguration.DiffTool
    var record: SnapshotTestingConfiguration.Record
}

private let globalState: LockIsolated<GlobalState> = {
    let record = ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"]
        .flatMap(SnapshotTestingConfiguration.Record.init(rawValue:))
        ?? .missing
    return LockIsolated(
        GlobalState(accessedSnapshotPaths: [], diffTool: .default, record: record)
    )
}()

enum SegmentedSnapshotName {
    @TaskLocal static var components: [String]?
}

/// The deduplicated reference file URLs read by snapshot assertions in this process.
///
/// Call ``resetAccessedSnapshotPaths()`` before collecting paths for a new test run. Do not reset
/// this value while snapshot assertions are running.
public var accessedSnapshotPaths: Set<URL> {
    globalState.withLock { $0.accessedSnapshotPaths }
}

/// Clears the reference file URLs collected in ``accessedSnapshotPaths``.
public func resetAccessedSnapshotPaths() {
    globalState.withLock { $0.accessedSnapshotPaths.removeAll() }
}

/// Enhances failure messages with a command line diff tool expression that can be copied and pasted
/// into a terminal.
@available(
    *,
    deprecated,
    message:
    "Use 'withSnapshotTesting' to customize the diff tool. See the documentation for more information."
) public var diffTool: SnapshotTestingConfiguration.DiffTool {
    get {
        _diffTool
    }
    set { _diffTool = newValue }
}

@_spi(Internals) public var _diffTool: SnapshotTestingConfiguration.DiffTool {
    get {
        #if canImport(Testing)
            if let test = Test.current {
                for trait in test.traits.reversed() {
                    if let diffTool = (trait as? _SnapshotsTestTrait)?.configuration.diffTool {
                        return diffTool
                    }
                }
            }
        #endif
        return __diffTool
    }
    set {
        __diffTool = newValue
    }
}

@_spi(Internals) public var __diffTool: SnapshotTestingConfiguration.DiffTool {
    get { globalState.withLock { $0.diffTool } }
    set { globalState.withLock { $0.diffTool = newValue } }
}

/// Whether or not to record all new references.
@available(
    *,
    deprecated,
    message:
    "Use 'withSnapshotTesting' to customize the record mode. See the documentation for more information."
) public var isRecording: Bool {
    get { SnapshotTestingConfiguration.current?.record ?? _record == .all }
    set { _record = newValue ? .all : .missing }
}

@_spi(Internals) public var _record: SnapshotTestingConfiguration.Record {
    get {
        #if canImport(Testing)
            if let test = Test.current {
                for trait in test.traits.reversed() {
                    if let record = (trait as? _SnapshotsTestTrait)?.configuration.record {
                        return record
                    }
                }
            }
        #endif
        return __record
    }
    set {
        __record = newValue
    }
}

@_spi(Internals) public var __record: SnapshotTestingConfiguration.Record {
    get { globalState.withLock { $0.record } }
    set { globalState.withLock { $0.record = newValue } }
}

/// Options that customize a snapshot assertion.
public struct SnapshotAssertionOptions: Sendable {
    public var record: SnapshotTestingConfiguration.Record?
    public var diffTool: SnapshotTestingConfiguration.DiffTool?
    public var snapshotDirectory: String?
    public var artifactsDirectory: String?
    public var timeout: TimeInterval

    public init(
        record: SnapshotTestingConfiguration.Record? = nil,
        diffTool: SnapshotTestingConfiguration.DiffTool? = nil,
        snapshotDirectory: String? = nil,
        artifactsDirectory: String? = nil,
        timeout: TimeInterval = 5
    ) {
        self.record = record
        self.diffTool = diffTool
        self.snapshotDirectory = snapshotDirectory
        self.artifactsDirectory = artifactsDirectory
        self.timeout = timeout
    }

    public func recording(_ record: SnapshotTestingConfiguration.Record?) -> Self {
        var copy = self
        copy.record = record
        return copy
    }

    public func usingDiffTool(_ diffTool: SnapshotTestingConfiguration.DiffTool?) -> Self {
        var copy = self
        copy.diffTool = diffTool
        return copy
    }

    public func savingSnapshots(in snapshotDirectory: String?) -> Self {
        var copy = self
        copy.snapshotDirectory = snapshotDirectory
        return copy
    }

    public func savingArtifacts(in artifactsDirectory: String?) -> Self {
        var copy = self
        copy.artifactsDirectory = artifactsDirectory
        return copy
    }

    public func waiting(upTo timeout: TimeInterval) -> Self {
        var copy = self
        copy.timeout = timeout
        return copy
    }
}

/// Asserts that a given value matches a reference on disk.
///
/// - Parameters:
///   - value: A value to compare against a reference.
///   - snapshotting: A strategy for serializing, deserializing, and comparing values.
///   - name: An optional description of the snapshot.
///   - options: Options controlling recording, diffing, directories, and timeout.
///   - fileID: The file ID in which failure occurred. Defaults to the file ID of the test case in
///     which this function was called.
///   - file: The file in which failure occurred. Defaults to the file path of the test case in
///     which this function was called.
///   - testName: The name of the test in which failure occurred. Defaults to the function name of
///     the test case in which this function was called.
///   - line: The line number on which failure occurred. Defaults to the line number on which this
///     function was called.
///   - column: The column on which failure occurred. Defaults to the column on which this function
///     was called.
@MainActor public func assertSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, some Any>,
    named name: String? = nil,
    options: SnapshotAssertionOptions = .init(),
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let failure = verifySnapshot(
        of: try value(),
        as: snapshotting,
        named: name,
        options: options,
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
    guard let message = failure else {
        return
    }
    recordIssue(
        message,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

@available(*, deprecated, message: "Use the 'options:' parameter instead.")
@MainActor @_disfavoredOverload public func assertSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, some Any>,
    named name: String? = nil,
    record: SnapshotTestingConfiguration.Record? = nil,
    snapshotDirectory: String? = nil,
    artifactsDirectory: String? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    assertSnapshot(
        of: try value(),
        as: snapshotting,
        named: name,
        options: SnapshotAssertionOptions(
            record: record,
            snapshotDirectory: snapshotDirectory,
            artifactsDirectory: artifactsDirectory,
            timeout: timeout
        ),
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

/// Asserts that a given value matches references on disk.
///
/// - Parameters:
///   - value: A value to compare against a reference.
///   - strategies: A dictionary of names and strategies for serializing, deserializing, and
///     comparing values.
///   - options: Options controlling recording, diffing, directories, and timeout.
///   - fileID: The file ID in which failure occurred. Defaults to the file ID of the test case in
///     which this function was called.
///   - file: The file in which failure occurred. Defaults to the file path of the test case in
///     which this function was called.
///   - testName: The name of the test in which failure occurred. Defaults to the function name of
///     the test case in which this function was called.
///   - line: The line number on which failure occurred. Defaults to the line number on which this
///     function was called.
///   - column: The column on which failure occurred. Defaults to the column on which this function
///     was called.
@MainActor public func assertSnapshots<Value>(
    of value: @autoclosure () throws -> Value,
    as strategies: [String: Snapshotting<Value, some Any>],
    options: SnapshotAssertionOptions = .init(),
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    try? strategies.forEach { name, strategy in
        assertSnapshot(
            of: try value(),
            as: strategy,
            named: name,
            options: options,
            fileID: fileID,
            file: filePath,
            testName: testName,
            line: line,
            column: column
        )
    }
}

@available(*, deprecated, message: "Use the 'options:' parameter instead.")
@MainActor @_disfavoredOverload public func assertSnapshots<Value>(
    of value: @autoclosure () throws -> Value,
    as strategies: [String: Snapshotting<Value, some Any>],
    record: SnapshotTestingConfiguration.Record? = nil,
    snapshotDirectory: String? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    assertSnapshots(
        of: try value(),
        as: strategies,
        options: SnapshotAssertionOptions(
            record: record,
            snapshotDirectory: snapshotDirectory,
            timeout: timeout
        ),
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

/// Asserts that a given value matches references on disk.
///
/// - Parameters:
///   - value: A value to compare against a reference.
///   - strategies: An array of strategies for serializing, deserializing, and comparing values.
///   - options: Options controlling recording, diffing, directories, and timeout.
///   - fileID: The file ID in which failure occurred. Defaults to the file ID of the test case in
///     which this function was called.
///   - file: The file in which failure occurred. Defaults to the file path of the test case in
///     which this function was called.
///   - testName: The name of the test in which failure occurred. Defaults to the function name of
///     the test case in which this function was called.
///   - line: The line number on which failure occurred. Defaults to the line number on which this
///     function was called.
///   - column: The column on which failure occurred. Defaults to the column on which this function
///     was called.
@MainActor public func assertSnapshots<Value>(
    of value: @autoclosure () throws -> Value,
    as strategies: [Snapshotting<Value, some Any>],
    options: SnapshotAssertionOptions = .init(),
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    try? strategies.forEach { strategy in
        assertSnapshot(
            of: try value(),
            as: strategy,
            options: options,
            fileID: fileID,
            file: filePath,
            testName: testName,
            line: line,
            column: column
        )
    }
}

@available(*, deprecated, message: "Use the 'options:' parameter instead.")
@MainActor @_disfavoredOverload public func assertSnapshots<Value>(
    of value: @autoclosure () throws -> Value,
    as strategies: [Snapshotting<Value, some Any>],
    record: SnapshotTestingConfiguration.Record? = nil,
    snapshotDirectory: String? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    assertSnapshots(
        of: try value(),
        as: strategies,
        options: SnapshotAssertionOptions(
            record: record,
            snapshotDirectory: snapshotDirectory,
            timeout: timeout
        ),
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

/// Verifies that a given value matches a reference on disk.
///
/// Third party snapshot assert helpers can be built on top of this function. Simply invoke
/// `verifySnapshot` with your own arguments, and then invoke `XCTFail` with the string returned if
/// it is non-`nil`. For example, if you want the snapshot directory to be determined by an
/// environment variable, you can create your own assert helper like so:
///
/// ```swift
/// public func myAssertSnapshot<Value, Format>(
///   of value: @autoclosure () throws -> Value,
///   as snapshotting: Snapshotting<Value, Format>,
///   named name: String? = nil,
///   record: SnapshotTestingConfiguration.Record? = nil,
///   timeout: TimeInterval = 5,
///   file: StaticString = #filePath,
///   testName: String = #function,
///   line: UInt = #line
///   ) {
///
///     let snapshotDirectory = ProcessInfo.processInfo.environment["SNAPSHOT_REFERENCE_DIR"]! + "/" + #file
///     let failure = verifySnapshot(
///       of: try value(),
///       as: snapshotting,
///       named: name,
///       options: SnapshotAssertionOptions(
///         record: record,
///         snapshotDirectory: snapshotDirectory,
///         timeout: timeout
///       ),
///       file: file,
///       testName: testName
///     )
///     guard let message = failure else { return }
///     XCTFail(message, file: file, line: line)
/// }
/// ```
///
/// - Parameters:
///   - value: A value to compare against a reference.
///   - snapshotting: A strategy for serializing, deserializing, and comparing values.
///   - name: An optional description of the snapshot.
///   - options: Options controlling recording, diffing, directories, and timeout.
///   - file: The file in which failure occurred. Defaults to the file name of the test case in
///     which this function was called.
///   - testName: The name of the test in which failure occurred. Defaults to the function name of
///     the test case in which this function was called.
///   - line: The line number on which failure occurred. Defaults to the line number on which this
///     function was called.
/// - Returns: A failure message or, if the value matches, nil.
@MainActor public func verifySnapshot<Value, Format>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, Format>,
    named name: String? = nil,
    options: SnapshotAssertionOptions = .init(),
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) -> String? {
    #if canImport(Testing)
        if Test.current == nil {
            CleanCounterBetweenTestCases.registerIfNeeded()
        }
    #else
        CleanCounterBetweenTestCases.registerIfNeeded()
    #endif

    let record = options.record ?? SnapshotTestingConfiguration.current?.record ?? _record
    return withSnapshotTesting(record: record, diffTool: options.diffTool) { () -> String? in
        do {
            let fileUrl = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
            let fileName = fileUrl.deletingPathExtension().lastPathComponent

            let snapshotDirectoryUrl = try snapshotDirectoryURL(
                explicitPath: options.snapshotDirectory,
                referenceStorage: SnapshotTestingConfiguration.current?.referenceStorage,
                fileID: "\(fileID)",
                filePath: fileUrl.path
            )
            let explicitArtifactsDirectory = options.artifactsDirectory.flatMap {
                $0.allSatisfy(\.isWhitespace) ? nil : $0
            }

            let testName = sanitizePathComponent(testName)
            let snapshotNaming = SnapshotTestingConfiguration.current?.snapshotNaming ?? .numbered
            let pathComponent: String
            if let components = SegmentedSnapshotName.components {
                pathComponent = ([testName] + components.map(sanitizePathComponent)).joined(separator: ".")
            } else if let name {
                pathComponent = "\(testName).\(sanitizePathComponent(name))"
            } else {
                let identifier = snapshotNaming == .numbered
                    ? ".\(counter.next(for: snapshotDirectoryUrl.appendingPathComponent(testName).absoluteString))"
                    : ""
                pathComponent = "\(testName)\(identifier)"
            }

            var snapshotFileUrl = snapshotDirectoryUrl.appendingPathComponent(pathComponent)
            if let ext = snapshotting.pathExtension {
                snapshotFileUrl = snapshotFileUrl.appendingPathExtension(ext)
            }
            if name == nil,
               snapshotNaming == .testName,
               counter.next(for: "unnumbered:\(snapshotFileUrl.absoluteString)") > 1 {
                return """
                Multiple unnamed snapshots would use the same reference: \(snapshotFileUrl.path)
                Name additional snapshots with 'named:' or use snapshot naming '.numbered'.
                """
            }
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: snapshotDirectoryUrl.path) {
                try fileManager.createDirectory(at: snapshotDirectoryUrl, withIntermediateDirectories: true)
            }

            let tookSnapshot = XCTestExpectation(description: "Took snapshot")
            var optionalDiffable: Format?
            snapshotting.snapshot(try value()).run { b in
                optionalDiffable = b
                tookSnapshot.fulfill()
            }
            // NB: Most strategies complete synchronously, so only wait when the snapshot is still pending.
            let result = optionalDiffable != nil
                ? .completed
                : XCTWaiter.wait(for: [tookSnapshot], timeout: options.timeout)
            switch result {
                case .completed:
                    break
                case .timedOut:
                    return """
                    Exceeded timeout of \(options.timeout) seconds waiting for snapshot.

                    This can happen when an asynchronously rendered view (like a web view) has not loaded. \
                    Ensure that every subview of the view hierarchy has loaded to avoid timeouts, or, if a \
                    timeout is unavoidable, consider setting the "timeout" parameter of "assertSnapshot" to \
                    a higher value.
                    """
                case .incorrectOrder,
                     .invertedFulfillment,
                     .interrupted:
                    return "Couldn't snapshot value"
                @unknown default:
                    return "Couldn't snapshot value"
            }

            guard var diffable = optionalDiffable else {
                return "Couldn't snapshot value"
            }

            // NB: Encoding can be expensive (e.g. PNG), so encode the snapshot at most once.
            var cachedSnapshotData: Data?
            @MainActor func encodedSnapshot() -> Data {
                if let cachedSnapshotData {
                    return cachedSnapshotData
                }
                let data = snapshotting.diffing.toData(diffable)
                cachedSnapshotData = data
                return data
            }

            @MainActor func recordSnapshot(writeToDisk: Bool) throws {
                let snapshotData = encodedSnapshot()

                if writeToDisk {
                    try snapshotData.write(to: snapshotFileUrl)
                }

                if isSwiftTesting {
                    recordSwiftTestingAttachment(
                        snapshotData,
                        named: snapshotFileUrl.lastPathComponent,
                        sourceLocation: SourceLocation(
                            fileID: fileID.description,
                            filePath: filePath.description,
                            line: Int(line),
                            column: Int(column)
                        )
                    )
                } else {
                    #if !os(Android) && !os(Linux) && !os(Windows)
                        if ProcessInfo.processInfo.environment.keys.contains("__XCODE_BUILT_PRODUCTS_DIR_PATHS") {
                            XCTContext.runActivity(named: "Attached Recorded Snapshot") { activity in
                                if writeToDisk {
                                    // Snapshot was written to disk. Create attachment from file
                                    let attachment = XCTAttachment(contentsOfFile: snapshotFileUrl)
                                    activity.add(attachment)
                                } else {
                                    // Snapshot was not written to disk. Create attachment from data and path extension
                                    let typeIdentifier = snapshotting.pathExtension.flatMap(
                                        uniformTypeIdentifier(fromExtension:)
                                    )

                                    let attachment = XCTAttachment(
                                        uniformTypeIdentifier: typeIdentifier,
                                        name: snapshotFileUrl.lastPathComponent,
                                        payload: snapshotData
                                    )

                                    activity.add(attachment)
                                }
                            }
                        }
                    #endif
                }
            }

            @MainActor func recordArtifact() throws -> URL {
                let artifactsUrl = snapshotArtifactsDirectory(explicitArtifactsDirectory)
                let artifactsSubUrl = artifactsUrl.appendingPathComponent(fileName)
                try fileManager.createDirectory(
                    at: artifactsSubUrl,
                    withIntermediateDirectories: true
                )
                let failedSnapshotFileUrl = artifactsSubUrl.appendingPathComponent(
                    snapshotFileUrl.lastPathComponent
                )
                try encodedSnapshot().write(to: failedSnapshotFileUrl)
                return failedSnapshotFileUrl
            }

            @MainActor func recordMissingSnapshot() throws -> String {
                if record == .never {
                    try recordSnapshot(writeToDisk: false)
                    if explicitArtifactsDirectory != nil {
                        _ = try recordArtifact()
                    }

                    return """
                    No reference was found on disk. New snapshot was not recorded because recording is disabled
                    """
                } else if explicitArtifactsDirectory != nil {
                    try recordSnapshot(writeToDisk: false)
                    _ = try recordArtifact()

                    return """
                    No reference was found on disk. Snapshot was not recorded because an artifacts directory is configured.
                    """
                } else {
                    try recordSnapshot(writeToDisk: true)

                    return """
                    No reference was found on disk. Automatically recorded snapshot: …

                    open "\(snapshotFileUrl.absoluteString)"

                    Re-run "\(testName)" to assert against the newly-recorded snapshot.
                    """
                }
            }

            if record == .all {
                try recordSnapshot(writeToDisk: true)

                return """
                Record mode is on. Automatically recorded snapshot: …

                open "\(snapshotFileUrl.absoluteString)"

                Turn record mode off and re-run "\(testName)" to assert against the newly-recorded snapshot
                """
            }

            guard fileManager.fileExists(atPath: snapshotFileUrl.path) else {
                return try recordMissingSnapshot()
            }

            let referenceFileUrl = snapshotFileUrl
            _ = globalState.withLock { $0.accessedSnapshotPaths.insert(referenceFileUrl) }
            let data = try Data(contentsOf: referenceFileUrl)
            guard let reference = snapshotting.diffing.fromDataOptional(data) else {
                return "Failed to serialize \(snapshotFileUrl) as \(Format.self)"
            }

            #if os(iOS) || os(tvOS)
                // If the image generation fails for the diffable part and the reference was empty, use the reference
                if let localDiff = diffable as? UIImage,
                   let refImage = reference as? UIImage,
                   localDiff.size == .zero, refImage.size == .zero {
                    diffable = reference
                }
            #endif

            guard let (failure, attachments) = snapshotting.diffing.diffV2(reference, diffable) else {
                return nil
            }

            let failedSnapshotFileUrl = try recordArtifact()

            recordFailureAttachments(
                attachments,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            let diffMessage = (SnapshotTestingConfiguration.current?.diffTool ?? _diffTool)(
                currentFilePath: snapshotFileUrl.path,
                failedFilePath: failedSnapshotFileUrl.path
            )

            var failureMessage = if let name {
                "Snapshot \"\(name)\" does not match reference."
            } else {
                "Snapshot does not match reference."
            }

            if record == .failed {
                let shouldWriteReference = explicitArtifactsDirectory == nil
                try recordSnapshot(writeToDisk: shouldWriteReference)
                if shouldWriteReference {
                    failureMessage += " A new snapshot was automatically recorded."
                }
            }

            return """
            \(failureMessage)

            \(diffMessage)

            \(failure.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        } catch {
            return error.localizedDescription
        }
    }
}

@available(*, deprecated, message: "Use the 'options:' parameter instead.")
@MainActor @_disfavoredOverload public func verifySnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, some Any>,
    named name: String? = nil,
    record: SnapshotTestingConfiguration.Record? = nil,
    diffTool: SnapshotTestingConfiguration.DiffTool? = nil,
    snapshotDirectory: String? = nil,
    artifactsDirectory: String? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) -> String? {
    verifySnapshot(
        of: try value(),
        as: snapshotting,
        named: name,
        options: SnapshotAssertionOptions(
            record: record,
            diffTool: diffTool,
            snapshotDirectory: snapshotDirectory,
            artifactsDirectory: artifactsDirectory,
            timeout: timeout
        ),
        fileID: fileID,
        file: filePath,
        testName: testName,
        line: line,
        column: column
    )
}

// MARK: - Private

private var counter: File.Counter {
    #if canImport(Testing)
        if Test.current != nil {
            return File.counter
        } else {
            return _counter
        }
    #else
        return _counter
    #endif
}

private let _counter = File.Counter()

@MainActor private func recordFailureAttachments(
    _ attachments: [DiffAttachment],
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    guard !attachments.isEmpty else {
        return
    }
    if isSwiftTesting {
        for attachment in attachments {
            switch attachment {
                case .xcTest:
                    break
                case let .data(data, name):
                    recordSwiftTestingAttachment(
                        data,
                        named: name,
                        sourceLocation: SourceLocation(
                            fileID: fileID.description,
                            filePath: filePath.description,
                            line: Int(line),
                            column: Int(column)
                        )
                    )
            }
        }
    } else {
        #if !os(Linux) && !os(Android) && !os(Windows)
            guard ProcessInfo.processInfo.environment.keys.contains("__XCODE_BUILT_PRODUCTS_DIR_PATHS") else {
                return
            }
            XCTContext.runActivity(named: "Attached Failure Diff") { activity in
                for item in attachments {
                    switch item {
                        case let .xcTest(attachment):
                            activity.add(attachment)
                        case let .data(data, name):
                            let attachment = XCTAttachment(
                                uniformTypeIdentifier: uniformTypeIdentifier(
                                    fromExtension: (name as NSString).pathExtension
                                ),
                                name: name,
                                payload: data
                            )
                            activity.add(attachment)
                    }
                }
            }
        #endif
    }
}

func sanitizePathComponent(_ string: String) -> String {
    string
        .replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
}

enum SnapshotReferenceStorageError: Error, Equatable, LocalizedError {
    case invalidDirectory(String)
    case testTargetNotFound(module: String, filePath: String)

    var errorDescription: String? {
        switch self {
            case let .invalidDirectory(directory):
                "Reference storage directory '\(directory)' must be a non-empty relative path without '.' or '..' components."
            case let .testTargetNotFound(module, filePath):
                "Could not locate test target directory '\(module)' in source path '\(filePath)'. Use an explicit snapshot directory for custom source layouts."
        }
    }
}

func snapshotDirectoryURL(
    explicitPath: String?,
    referenceStorage: SnapshotTestingConfiguration.ReferenceStorage?,
    fileID: String,
    filePath: String,
    androidBaseURL: URL? = defaultAndroidSnapshotsBaseURL
) throws -> URL {
    if let explicitPath {
        return URL(fileURLWithPath: explicitPath, isDirectory: true)
    }

    let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
    let fileName = fileURL.deletingPathExtension().lastPathComponent
    guard let referenceStorage else {
        let baseURL = androidBaseURL ?? fileURL.deletingLastPathComponent()
        return baseURL
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: true)
    }

    switch referenceStorage {
        case let .directory(directory, relativeTo: .testTarget):
            let directoryComponents = try validatedRelativePathComponents(directory)
            let module = fileID.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let sourceDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
            guard !module.isEmpty,
                  let targetDirectory = nearestAncestor(named: module, from: sourceDirectory) else {
                throw SnapshotReferenceStorageError.testTargetNotFound(
                    module: module,
                    filePath: filePath
                )
            }

            let targetComponents = targetDirectory.pathComponents
            let sourceComponents = sourceDirectory.pathComponents
            let relativeSourceComponents = sourceComponents.dropFirst(targetComponents.count)
            var storageURL = androidBaseURL ?? targetDirectory
            for component in directoryComponents {
                storageURL.appendPathComponent(component, isDirectory: true)
            }
            for component in relativeSourceComponents {
                storageURL.appendPathComponent(component, isDirectory: true)
            }
            storageURL.appendPathComponent(fileName, isDirectory: true)
            return storageURL
    }
}

private func validatedRelativePathComponents(_ path: String) throws -> [String] {
    let isAbsolute = (path as NSString).isAbsolutePath
    let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    guard !path.allSatisfy(\.isWhitespace),
          !isAbsolute,
          !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw SnapshotReferenceStorageError.invalidDirectory(path)
    }
    return components
}

private func nearestAncestor(named name: String, from directory: URL) -> URL? {
    var candidate = directory
    while true {
        if candidate.lastPathComponent == name {
            return candidate
        }
        let parent = candidate.deletingLastPathComponent()
        guard parent.path != candidate.path else {
            return nil
        }
        candidate = parent
    }
}

private let defaultAndroidSnapshotsBaseURL: URL? = {
    #if os(Android)
        // Android CI copies snapshot references beneath this staging directory.
        URL(fileURLWithPath: "/data/local/tmp/android-xctest", isDirectory: true)
    #else
        nil
    #endif
}()

func snapshotArtifactsDirectory(
    _ explicitPath: String? = nil,
    environmentPath: String? = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"]
) -> URL {
    let explicitPath = explicitPath.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    let environmentPath = environmentPath.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    let path = explicitPath ?? environmentPath ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: path, isDirectory: true)
}

#if !os(Android) && !os(Linux) && !os(Windows)
    import UniformTypeIdentifiers

    func uniformTypeIdentifier(fromExtension pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.identifier
    }
#endif

/// We need to clean counter between tests executions in order to support test-iterations.
private class CleanCounterBetweenTestCases: NSObject, XCTestObservation {
    @MainActor private static var registered = false

    @MainActor static func registerIfNeeded() {
        guard !registered else {
            return
        }
        defer { registered = true }
        XCTestObservationCenter.shared.addTestObserver(CleanCounterBetweenTestCases())
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        _counter.reset()
    }
}

enum File {
    @TaskLocal static var counter = Counter()

    final class Counter: @unchecked Sendable {
        private var counts: [String: Int] = [:]
        private let lock = NSLock()

        init() {}

        func next(for key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            counts[key, default: 0] += 1
            return counts[key, default: 0]
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            counts.removeAll()
        }
    }
}

#if canImport(Testing)
    private func recordSwiftTestingAttachment(
        _ data: Data,
        named name: String,
        sourceLocation: SourceLocation
    ) {
        Attachment.record(SnapshotAttachment(data: data), named: name, sourceLocation: sourceLocation)
    }

    private struct SnapshotAttachment: Attachable, Sendable {
        let data: Data

        borrowing func withUnsafeBytes<R>(
            for attachment: borrowing Attachment<Self>,
            _ body: (UnsafeRawBufferPointer) throws -> R
        ) throws -> R {
            try data.withUnsafeBytes { buffer in
                try body(buffer)
            }
        }
    }
#endif
