import Foundation

func typeName(
    _ type: Any.Type,
    qualified: Bool = true,
    genericsAbbreviated: Bool = true
) -> String {
    let key = TypeNameCache.Key(
        type: ObjectIdentifier(type),
        qualified: qualified,
        genericsAbbreviated: genericsAbbreviated
    )
    return typeNameCache.value(for: key) {
        uncachedTypeName(type, qualified: qualified, genericsAbbreviated: genericsAbbreviated)
    }
}

// NB: Type names never change, and formatting one runs many regular expressions.
private let typeNameCache = TypeNameCache()

private final class TypeNameCache: @unchecked Sendable {
    struct Key: Hashable {
        let type: ObjectIdentifier
        let qualified: Bool
        let genericsAbbreviated: Bool
    }

    private var names: [Key: String] = [:]
    private let lock = NSLock()

    func value(for key: Key, _ makeName: () -> String) -> String {
        if let name = lock.withLock({ names[key] }) {
            return name
        }
        let name = makeName()
        lock.withLock { names[key] = name }
        return name
    }
}

private func uncachedTypeName(
    _ type: Any.Type,
    qualified: Bool,
    genericsAbbreviated: Bool
) -> String {
    var name = _typeName(type, qualified: qualified)
        .replacingOccurrences(
            of: #"\(unknown context at \$[[:xdigit:]]+\)\."#,
            with: "",
            options: .regularExpression
        )
    for _ in 1 ... 10 { // NB: Only handle so much nesting
        let abbreviated =
            name
                .replacingOccurrences(
                    of: #"\bSwift.Optional<([^><]+)>"#,
                    with: "$1?",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\bSwift.Array<([^><]+)>"#,
                    with: "[$1]",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\bSwift.Dictionary<([^,<]+), ([^><]+)>"#,
                    with: "[$1: $2]",
                    options: .regularExpression
                )
        if abbreviated == name {
            break
        }
        name = abbreviated
    }
    name = name.replacingOccurrences(
        of: #"\w+\.([\w.]+)"#,
        with: "$1",
        options: .regularExpression
    )
    if genericsAbbreviated {
        name = name.replacingOccurrences(
            of: #"<.+>"#,
            with: "",
            options: .regularExpression
        )
    }
    return name
}
