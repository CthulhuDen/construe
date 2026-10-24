import Foundation
import Testing
@testable import Construe

@MainActor
struct SampleFIFOTests {
    private func write(_ samples: [Float], channels: Int = 1, to fifo: SampleFIFO) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            fifo.write(interleaved: base, frames: samples.count / channels, channels: channels)
        }
    }

    private func read(_ maxCount: Int, from fifo: SampleFIFO) -> [Float] {
        var destination = [Float](repeating: 0, count: maxCount)
        let count = destination.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return fifo.read(into: base, maxCount: maxCount)
        }
        return Array(destination.prefix(count))
    }

    @Test func samplesComeOutInOrder() {
        let fifo = SampleFIFO(capacity: 8)
        write([1, 2, 3], to: fifo)
        write([4, 5], to: fifo)
        #expect(read(10, from: fifo) == [1, 2, 3, 4, 5])
        #expect(read(10, from: fifo).isEmpty)
    }

    @Test func wrapsAroundTheEnd() {
        let fifo = SampleFIFO(capacity: 4)
        write([1, 2, 3], to: fifo)
        #expect(read(2, from: fifo) == [1, 2])
        write([4, 5, 6], to: fifo)
        #expect(read(10, from: fifo) == [3, 4, 5, 6])
    }

    @Test func partialReadsLeaveTheRest() {
        let fifo = SampleFIFO(capacity: 8)
        write([1, 2, 3, 4], to: fifo)
        #expect(read(3, from: fifo) == [1, 2, 3])
        #expect(read(3, from: fifo) == [4])
    }

    @Test func overflowDropsNewSamplesAndCountsThem() {
        let fifo = SampleFIFO(capacity: 4)
        write([1, 2, 3], to: fifo)
        write([4, 5, 6], to: fifo)
        #expect(fifo.takeDroppedCount() == 2)
        #expect(fifo.takeDroppedCount() == 0)
        #expect(read(10, from: fifo) == [1, 2, 3, 4])
    }

    @Test func interleavedStereoIsMixedToMono() {
        let fifo = SampleFIFO(capacity: 8)
        write([0.2, 0.4, -1, 1, 0.5, 0.5], channels: 2, to: fifo)
        let samples = read(10, from: fifo)
        #expect(samples.count == 3)
        #expect(abs(samples[0] - 0.3) < 1e-6)
        #expect(samples[1] == 0)
        #expect(samples[2] == 0.5)
        #expect(fifo.channels == 2)
    }

    @Test func writeMarksTheProducerAlive() async throws {
        let fifo = SampleFIFO(capacity: 4)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fifo.timeSinceLastWrite >= .milliseconds(20))
        write([1], to: fifo)
        #expect(fifo.timeSinceLastWrite < .milliseconds(20))
    }
}
