import AVFoundation
import MacWashingKit

/// Gentle interface sounds, synthesized on the fly (no audio files): soft sine ticks, chimes and water noise.
final class SoundEngine: Sendable {
    enum Cue {
        case tick, untick, navigate, toggle, start, bubble, found, wash, done, trash, sheet, cancel
    }

    private enum Wave: Sendable { case sine, triangle, noise }

    private struct Voice: Sendable {
        var wave: Wave
        var frequency: Double
        var frequencyEnd: Double
        var startFrame: Int
        var frames: Int
        var volume: Double
        var phase: Double = 0
        // Band-pass state for noise voices (state-variable filter).
        var low: Double = 0
        var band: Double = 0
    }

    private struct State: Sendable {
        var voices: [Voice] = []
        var frame = 0
        var seed: UInt32 = 0x9E3779B9
    }

    /// Shared with the render callback.
    private let shared = Locked(State())
    private let sampleRate: Double
    private let engine: AVAudioEngine
    private let enabled = Locked(true)

    init() {
        let engine = AVAudioEngine()
        let format = engine.outputNode.outputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        self.engine = engine
        self.sampleRate = rate
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let shared = self.shared
        let source = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let pointer = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            shared.withLock { s in
                SoundEngine.render(into: pointer, count: Int(frameCount), state: &s, sampleRate: rate)
            }
            for index in 1..<buffers.count {
                buffers[index].mData?.copyMemory(from: pointer, byteCount: Int(frameCount) * MemoryLayout<Float>.size)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: monoFormat)
        engine.mainMixerNode.outputVolume = 0.8
        engine.prepare()
    }

    var isEnabled: Bool {
        get { enabled.load() }
        set { enabled.store(newValue) }
    }

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        if !engine.isRunning { try? engine.start() }
        switch cue {
        case .tick: tone(1480, 0, 0.06, 0.016)
        case .untick: tone(1040, 0, 0.06, 0.012)
        // Muffled, very quiet tap: low pitch sliding down, fast decay.
        case .navigate: tone(240, 0, 0.05, 0.0045, to: 170)
        case .toggle: tone(880, 0, 0.07, 0.016); tone(1320, 0.05, 0.09, 0.014)
        // Scan start and finish are as quiet and short as «Остановить»: two soft low notes, up to start, settling to finish.
        case .start: tone(349.23, 0, 0.12, 0.012); tone(440, 0.07, 0.14, 0.011)
        case .bubble: tone(.random(in: 520...900), 0, 0.09, 0.009, to: .random(in: 1300...1800))
        case .found: tone(440, 0, 0.12, 0.012); tone(392, 0.08, 0.18, 0.011)
        case .wash: noise(0, 0.9, 0.04, 400, 1800)
        case .done:
            for (index, frequency) in [523.25, 659.25, 783.99, 1046.5].enumerated() {
                tone(frequency, Double(index) * 0.08, 0.9, 0.032)
            }
            for index in 0..<4 {
                tone(.random(in: 700...1200), 0.35 + Double(index) * 0.09, 0.08, 0.01, to: 1600)
            }
        case .trash: noise(0, 0.5, 0.05, 1800, 300); tone(220, 0.05, 0.25, 0.016, to: 140)
        case .sheet: tone(440, 0, 0.18, 0.016)
        case .cancel: tone(392, 0, 0.12, 0.013)
        }
    }

    private func tone(_ frequency: Double, _ delay: Double, _ duration: Double, _ volume: Double, to end: Double? = nil, wave: Wave = .sine) {
        add(Voice(wave: wave, frequency: frequency, frequencyEnd: end ?? frequency, startFrame: 0, frames: 0, volume: volume), delay: delay, duration: duration)
    }

    private func noise(_ delay: Double, _ duration: Double, _ volume: Double, _ from: Double, _ to: Double) {
        add(Voice(wave: .noise, frequency: from, frequencyEnd: to, startFrame: 0, frames: 0, volume: volume), delay: delay, duration: duration)
    }

    private func add(_ voice: Voice, delay: Double, duration: Double) {
        let rate = sampleRate
        shared.withLock { s in
            var v = voice
            v.startFrame = s.frame + Int((delay + 0.005) * rate)
            v.frames = Int(duration * rate)
            // Cue volumes are given on a quiet 0…1 scale; bring them up to the mixer's level.
            v.volume *= 6
            s.voices.append(v)
        }
    }

    private static func render(into out: UnsafeMutablePointer<Float>, count: Int, state s: inout State, sampleRate: Double) {
        for i in 0..<count { out[i] = 0 }
        guard !s.voices.isEmpty else {
            s.frame += count
            return
        }
        for index in s.voices.indices {
            var v = s.voices[index]
            for i in 0..<count {
                let frame = s.frame + i - v.startFrame
                guard frame >= 0, frame < v.frames else { continue }
                let t = Double(frame) / Double(v.frames)
                let frequency = v.frequency * pow(v.frequencyEnd / v.frequency, min(t / 0.8, 1))
                // Fast attack, exponential decay.
                let attack = min(Double(frame) / (0.015 * sampleRate), 1)
                let envelope = attack * pow(0.0001, t)
                var sample: Double
                switch v.wave {
                case .sine:
                    sample = sin(v.phase * 2 * .pi)
                case .triangle:
                    sample = 1 - 4 * abs(v.phase - 0.5)
                case .noise:
                    s.seed = s.seed &* 1_664_525 &+ 1_013_904_223
                    let white = Double(s.seed) / Double(UInt32.max) * 2 - 1
                    let f = 2 * sin(.pi * min(frequency, sampleRate / 6) / sampleRate)
                    v.low += f * v.band
                    let high = white - v.low - 1.1 * v.band
                    v.band += f * high
                    sample = v.band
                }
                v.phase += frequency / sampleRate
                if v.phase >= 1 { v.phase -= 1 }
                out[i] += Float(sample * envelope * v.volume)
            }
            s.voices[index] = v
        }
        s.frame += count
        s.voices.removeAll { s.frame - $0.startFrame > $0.frames }
    }
}
