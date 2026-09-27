import Darwin
import Foundation

/// The baseline must come from a successful NoteReader read or a prior confirmed save.
struct NoteSaveRequest: Sendable {
    let baseline: NoteSnapshot
    let desiredContent: NoteContent
}

enum NoteWriteError: Error, LocalizedError, Equatable {
    case conflict
    case identityChanged
    case invalidContent
    case baselineReadFailed(operation: String, code: Int32)
    case writeFailed(operation: String, code: Int32)
    case resultUnconfirmed

    var resultWasUnconfirmed: Bool {
        if case .resultUnconfirmed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "笔记已在外部改变；已停止覆盖，当前草稿仍在编辑器中。"
        case .identityChanged:
            return "文件已消失、移动或被替换，或无法确认其身份；已停止保存，当前草稿仍在编辑器中。"
        case .invalidContent:
            return "只能保存有效的 UTF-8 笔记正文；当前草稿仍在编辑器中。"
        case .baselineReadFailed(let operation, let code):
            return "保存前读取笔记失败（\(operation)，\(code)：\(String(cString: strerror(code)))）；当前草稿仍在编辑器中。"
        case .writeFailed(let operation, let code):
            return "写入失败（\(operation)，\(code)：\(String(cString: strerror(code)))）；当前草稿仍在编辑器中。"
        case .resultUnconfirmed:
            return "写入后无法完整确认结果；当前草稿已保留。请先复制或导出，再重新打开文件核对。"
        }
    }
}

/// Writes only FinderNotes' own xattr. A successful result is a new baseline, not an editor update.
struct NoteWriter: Sendable {
    #if DEBUG
    /// Test hooks exercise races on either side of the write; release builds have no hooks.
    private let beforeFinalValidation: (@Sendable () throws -> Void)?
    private let beforeReadback: (@Sendable () throws -> Void)?

    init(beforeFinalValidation: (@Sendable () throws -> Void)? = nil,
         beforeReadback: (@Sendable () throws -> Void)? = nil) {
        self.beforeFinalValidation = beforeFinalValidation
        self.beforeReadback = beforeReadback
    }
    #else
    init() {}
    #endif

    func save(_ request: NoteSaveRequest) throws -> NoteSnapshot {
        let desired: Data
        guard case .present(let bytes) = request.desiredContent,
              String(data: bytes, encoding: .utf8) != nil else {
            throw NoteWriteError.invalidContent
        }
        desired = bytes

        if case .present(let baselineBytes) = request.baseline.content,
           String(data: baselineBytes, encoding: .utf8) == nil {
            throw NoteWriteError.invalidContent
        }
        let input = request.baseline.url
        // A manual save with identical existing bytes still verifies the target and baseline,
        // but requires only read access and must not update the xattr or its metadata.
        // Missing -> present(empty) remains an explicit write.
        let isVerifiedNoOp = request.baseline.content == request.desiredContent
        guard input.isFileURL,
              input.host == nil || input.host == "" || input.host?.lowercased() == "localhost",
              input.query == nil, input.fragment == nil,
              let path = try? NoteReader.localPath(input.path) else {
            throw NoteWriteError.identityChanged
        }

        let fd: Int32
        do { fd = try NoteReader.openPath(path, access: isVerifiedNoOp ? O_RDONLY : O_RDWR) }
        catch NoteReadError.system(let operation, let code) where code == EACCES || code == EPERM || code == EROFS {
            throw NoteWriteError.writeFailed(operation: operation, code: code)
        }
        catch { throw NoteWriteError.identityChanged }
        defer { close(fd) }

        try validateTarget(fd: fd, path: path, expected: request.baseline.identity)
        try validateBaseline(fd: fd, expected: request.baseline.content)

        #if DEBUG
        try beforeFinalValidation?()
        #endif
        // This check is as close to fsetxattr as the API permits. It is not a bytewise CAS:
        // another process may change existing bytes between this check and the write.
        try validateTarget(fd: fd, path: path, expected: request.baseline.identity)
        try validateBaseline(fd: fd, expected: request.baseline.content)

        if isVerifiedNoOp {
            return NoteSnapshot(url: URL(fileURLWithPath: path), identity: request.baseline.identity,
                                content: .present(desired))
        }

        let flags: Int32
        switch request.baseline.content {
        case .missing: flags = XATTR_CREATE
        case .present: flags = XATTR_REPLACE
        }
        let result = desired.withUnsafeBytes { rawBytes in
            fsetxattr(fd, NoteReader.attributeName, rawBytes.baseAddress, desired.count, 0, flags)
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST || code == ENOATTR { throw NoteWriteError.conflict }
            throw NoteWriteError.writeFailed(operation: "写入笔记扩展属性", code: code)
        }

        // From this point a failed check cannot assert that the old bytes survived.
        do {
            #if DEBUG
            try beforeReadback?()
            #endif
            guard try NoteReader.attribute(fd, name: NoteReader.attributeName) == desired else {
                throw NoteWriteError.resultUnconfirmed
            }
            try validateTarget(fd: fd, path: path, expected: request.baseline.identity)
        } catch {
            throw NoteWriteError.resultUnconfirmed
        }
        return NoteSnapshot(url: URL(fileURLWithPath: path), identity: request.baseline.identity,
                            content: .present(desired))
    }

    private func validateTarget(fd: Int32, path: String, expected: FileIdentity) throws {
        let held: stat
        do { held = try NoteReader.regularStatus(fd) }
        catch { throw NoteWriteError.identityChanged }
        guard FileIdentity(held) == expected else { throw NoteWriteError.identityChanged }

        // A second traversal rejects both final-component and parent-directory replacement.
        let currentFD: Int32
        do { currentFD = try NoteReader.openPath(path) }
        catch { throw NoteWriteError.identityChanged }
        defer { close(currentFD) }
        let current: stat
        do { current = try NoteReader.regularStatus(currentFD) }
        catch { throw NoteWriteError.identityChanged }
        guard FileIdentity(current) == expected else { throw NoteWriteError.identityChanged }
    }

    private func validateBaseline(fd: Int32, expected: NoteContent) throws {
        let current: NoteContent
        do {
            if let bytes = try NoteReader.attribute(fd, name: NoteReader.attributeName) {
                current = .present(bytes)
            } else {
                current = .missing
            }
        } catch NoteReadError.system(let operation, let code) {
            throw NoteWriteError.baselineReadFailed(operation: operation, code: code)
        } catch NoteReadError.attributeChanging {
            throw NoteWriteError.conflict
        } catch {
            throw NoteWriteError.conflict
        }
        guard current == expected else { throw NoteWriteError.conflict }
    }
}
