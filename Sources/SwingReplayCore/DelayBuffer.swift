import Foundation

public final class DelayBuffer<Element> {
    private struct Entry {
        let enqueueTime: TimeInterval
        let value: Element
    }

    private var queue: [Entry] = []

    public let targetDelay: TimeInterval
    public let maxCount: Int

    public init(targetDelay: TimeInterval, maxCount: Int = 240) {
        self.targetDelay = max(0, targetDelay)
        self.maxCount = max(1, maxCount)
    }

    public var count: Int {
        queue.count
    }

    public func append(_ value: Element, now: TimeInterval = Date().timeIntervalSince1970) {
        queue.append(Entry(enqueueTime: now, value: value))

        if queue.count > maxCount {
            let overflow = queue.count - maxCount
            queue.removeFirst(overflow)
        }
    }

    public func popReady(now: TimeInterval = Date().timeIntervalSince1970) -> Element? {
        guard let first = queue.first else {
            return nil
        }

        guard now - first.enqueueTime >= targetDelay else {
            return nil
        }

        queue.removeFirst()
        return first.value
    }

    public func clear() {
        queue.removeAll(keepingCapacity: false)
    }
}
