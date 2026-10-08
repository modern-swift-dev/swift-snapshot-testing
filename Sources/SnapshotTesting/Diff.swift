import Foundation

struct Difference<A> {
    enum Which {
        case first
        case second
        case both
    }

    let elements: [A]
    let which: Which
}

func diff<A: Hashable>(_ fst: [A], _ snd: [A]) -> [Difference<A>] {
    var differences: [Difference<A>] = []
    diff(fst[...], snd[...], into: &differences)
    return differences
}

private func diff<A: Hashable>(
    _ fst: ArraySlice<A>,
    _ snd: ArraySlice<A>,
    into differences: inout [Difference<A>]
) {
    var idxsOf = [A: [Int]]()
    for fstIdx in fst.indices {
        idxsOf[fst[fstIdx], default: []].append(fstIdx)
    }

    // NB: Reuse two overlap rows in place; copying a row per match makes repeated lines very slow.
    var previousOverlap = [Int: Int]()
    var overlap = [Int: Int]()
    var fstIdx = fst.startIndex
    var sndIdx = snd.startIndex
    var len = 0
    for sndOffset in snd.indices {
        let rowLen = len
        overlap.removeAll(keepingCapacity: true)
        for matchIdx in idxsOf[snd[sndOffset]] ?? [] {
            let newLen = (previousOverlap[matchIdx - 1] ?? 0) + 1
            overlap[matchIdx] = newLen
            if newLen > rowLen {
                fstIdx = matchIdx - newLen + 1
                sndIdx = sndOffset - newLen + 1
                len = newLen
            }
        }
        swap(&previousOverlap, &overlap)
    }

    if len == 0 {
        if !fst.isEmpty {
            differences.append(Difference(elements: Array(fst), which: .first))
        }
        if !snd.isEmpty {
            differences.append(Difference(elements: Array(snd), which: .second))
        }
    } else {
        diff(fst[..<fstIdx], snd[..<sndIdx], into: &differences)
        differences.append(Difference(elements: Array(fst[fstIdx ..< fstIdx + len]), which: .both))
        diff(fst[(fstIdx + len)...], snd[(sndIdx + len)...], into: &differences)
    }
}

let minus = "−"
let plus = "+"
private let figureSpace = "\u{2007}"

struct Hunk {
    var fstIdx: Int
    var fstLen: Int
    var sndIdx: Int
    var sndLen: Int
    var lines: [String]

    var patchMark: String {
        let fstMark = "\(minus)\(fstIdx + 1),\(fstLen)"
        let sndMark = "\(plus)\(sndIdx + 1),\(sndLen)"
        return "@@ \(fstMark) \(sndMark) @@"
    }

    // Semigroup

    static func + (lhs: Hunk, rhs: Hunk) -> Hunk {
        Hunk(
            fstIdx: lhs.fstIdx + rhs.fstIdx,
            fstLen: lhs.fstLen + rhs.fstLen,
            sndIdx: lhs.sndIdx + rhs.sndIdx,
            sndLen: lhs.sndLen + rhs.sndLen,
            lines: lhs.lines + rhs.lines
        )
    }

    static func += (lhs: inout Hunk, rhs: Hunk) {
        lhs.fstIdx += rhs.fstIdx
        lhs.fstLen += rhs.fstLen
        lhs.sndIdx += rhs.sndIdx
        lhs.sndLen += rhs.sndLen
        lhs.lines += rhs.lines
    }

    // Monoid

    init(fstIdx: Int = 0, fstLen: Int = 0, sndIdx: Int = 0, sndLen: Int = 0, lines: [String] = []) {
        self.fstIdx = fstIdx
        self.fstLen = fstLen
        self.sndIdx = sndIdx
        self.sndLen = sndLen
        self.lines = lines
    }

    init(idx: Int = 0, len: Int = 0, lines: [String] = []) {
        self.init(fstIdx: idx, fstLen: len, sndIdx: idx, sndLen: len, lines: lines)
    }
}

func chunk(diff diffs: [Difference<String>], context ctx: Int = 4) -> [Hunk] {
    func prepending(_ prefix: String) -> (String) -> String {
        { prefix + $0 + ($0.hasSuffix(" ") ? "¬" : "") }
    }
    let changed: (Hunk) -> Bool = {
        $0.lines.contains(where: { $0.hasPrefix(minus) || $0.hasPrefix(plus) })
    }

    var current = Hunk()
    var hunks: [Hunk] = []
    for diff in diffs {
        let len = diff.elements.count

        switch diff.which {
            case .both where len > ctx * 2:
                let next = Hunk(
                    fstIdx: current.fstIdx + current.fstLen + len - ctx,
                    fstLen: ctx,
                    sndIdx: current.sndIdx + current.sndLen + len - ctx,
                    sndLen: ctx,
                    lines: (diff.elements.suffix(ctx) as ArraySlice<String>).map(prepending(figureSpace))
                )
                current += Hunk(len: ctx, lines: diff.elements.prefix(ctx).map(prepending(figureSpace)))
                if changed(current) {
                    hunks.append(current)
                }
                current = next
            case .both where current.lines.isEmpty:
                let lines = (diff.elements.suffix(ctx) as ArraySlice<String>).map(prepending(figureSpace))
                let count = lines.count
                current += Hunk(idx: len - count, len: count, lines: lines)
            case .both:
                current += Hunk(len: len, lines: diff.elements.map(prepending(figureSpace)))
            case .first:
                current += Hunk(fstLen: len, lines: diff.elements.map(prepending(minus)))
            case .second:
                current += Hunk(sndLen: len, lines: diff.elements.map(prepending(plus)))
        }
    }

    if changed(current) {
        hunks.append(current)
    }
    return hunks
}
