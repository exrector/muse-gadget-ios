// The depacketizer is ported from the Muse Gadget SDK, branch anantn/linux-video-calls (commit
// 77c7e27), linux/src/musegadget/rtc/rtp.py. Copyright (c) Meta Platforms, Inc. and affiliates.
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

/// Reassembles RTP H.264 (RFC 6184) into access units; drops a unit on loss or overflow and
/// waits for the next keyframe, as the SDK's H264Depacketizer.
final class MuseH264Depacketizer {
    private static let maxUnitBytes = 2 * 1024 * 1024
    private static let maxUnitNALs = 256

    private var nals: [Data] = []
    private var bytes = 0
    private var fragment: Data?
    private var expectedSequence: UInt16?
    private var broken = false
    private(set) var needsKeyframe = true

    /// The NAL units of a finished access unit, without start codes, or nil.
    func push(_ packet: MuseRTPPacket) -> [Data]? {
        if let expected = expectedSequence, packet.sequence != expected { drop() }
        expectedSequence = packet.sequence &+ 1
        if !broken {
            consume(packet.payload)
            if bytes > Self.maxUnitBytes || nals.count > Self.maxUnitNALs { drop() }
        }
        guard packet.marker else { return nil }
        if fragment != nil { drop() }  // a fragmented NAL left unfinished at the marker
        let unit = nals
        let wasBroken = broken
        nals = []
        bytes = 0
        fragment = nil
        broken = false
        guard !wasBroken, !unit.isEmpty else { return nil }
        if unit.contains(where: { $0.first.map { $0 & 0x1F == 5 } ?? false }) { needsKeyframe = false }
        return needsKeyframe ? nil : unit
    }

    private func drop() {
        nals = []
        bytes = 0
        fragment = nil
        broken = true
        needsKeyframe = true
    }

    private func consume(_ payload: Data) {
        let data = [UInt8](payload)
        guard let first = data.first else { return }
        bytes += data.count
        let kind = first & 0x1F
        if (1...23).contains(kind) {
            nals.append(payload)
        } else if kind == 24 {  // STAP-A
            var offset = 1
            while offset + 2 <= data.count {
                let size = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                if size > 0, offset + size <= data.count { nals.append(Data(data[offset..<(offset + size)])) }
                offset += size
            }
        } else if kind == 28, data.count >= 2 {  // FU-A; the fragment itself may be empty
            let start = data[1] & 0x80 != 0
            let end = data[1] & 0x40 != 0
            if start { fragment = Data([first & 0xE0 | data[1] & 0x1F]) }
            guard fragment != nil else {
                drop()  // a fragment without its start
                return
            }
            fragment?.append(contentsOf: data[2...])
            if end, let whole = fragment {
                nals.append(whole)
                fragment = nil
            }
        }
    }
}

/// Shows Muse's H.264 video with the system's hardware decoder: access units become
/// length-prefixed sample buffers for an AVSampleBufferDisplayLayer. Main thread only.
///
/// Each frame is shown at its RTP time (90 kHz) on a clock that runs `delay` behind the first
/// frame, as a player such as mpv or ffplay (the SDK's video outputs) paces by timestamps. That
/// smooths uneven delivery, and with the same 600 ms that replies' audio waits before playing,
/// Muse's lips stay with its voice instead of running ahead of it.
/// Where Muse's avatar is in its video, so a window of another shape can frame the avatar itself.
/// Muse renders every avatar on white, so whatever is not near-white is the avatar.
enum MuseSubjectFraming {
    /// The normalized box of the luma samples darker than `threshold`, or nil for a blank frame.
    static func bounds(luma: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                       threshold: UInt8 = 225, step: Int = 4) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        var y = 0
        while y < height {
            let row = luma + y * rowBytes
            var x = 0
            while x < width {
                if row[x] < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += step
            }
            y += step
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: CGFloat(minX) / w, y: CGFloat(minY) / h,
                      width: CGFloat(min(maxX + step, width) - minX) / w,
                      height: CGFloat(min(maxY + step, height) - minY) / h)
    }

    /// The video layer's frame inside `bounds` that shows the avatar (`subject`, normalized within a
    /// `video`-sized picture) whole and centred, with `margin` of the window on each side. A small
    /// avatar is enlarged at most to fill the window with the picture, so it never turns into a blur.
    static func layerFrame(bounds: CGSize, video: CGSize, subject: CGRect, margin: CGFloat = 0.03) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, video.width > 0, video.height > 0,
              subject.width > 0, subject.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let room = 1 - 2 * margin
        let fitSubject = min(bounds.width * room / (subject.width * video.width),
                             bounds.height * room / (subject.height * video.height))
        let fillPicture = max(bounds.width / video.width, bounds.height / video.height)
        let scale = min(fitSubject, fillPicture * 1.5)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        let centre = CGPoint(x: (subject.midX) * size.width, y: (subject.midY) * size.height)
        return CGRect(x: bounds.width / 2 - centre.x, y: bounds.height / 2 - centre.y,
                      width: size.width, height: size.height)
    }
}

final class MuseVideoRenderer {
    /// The avatar's box in the picture (normalized), grown with each keyframe looked at, so a
    /// gesture or a lean is never cut off. Called on the main queue.
    var onSubject: ((CGRect) -> Void)?
    private var subject: CGRect?
    private var keyframesLooked = 0
    private var keyframesSeen = 0
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMVideoFormatDescription?
    static let delay: TimeInterval = 0.6
    private var timebase: CMTimebase?
    private var lastRaw: UInt32?
    private var wraps: Int64 = 0
    let layer = AVSampleBufferDisplayLayer()
    /// Asked when the picture needs a fresh keyframe: the layer failed or no format is known yet.
    var onNeedsKeyframe: (() -> Void)?
    /// The picture's size from the stream's parameter sets, once known.
    var onSize: ((CGSize) -> Void)?
    private(set) var framesShown = 0
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init() {
        layer.videoGravity = .resizeAspect
    }

    func reset() {
        layer.flushAndRemoveImage()
        layer.controlTimebase = nil
        timebase = nil
        lastRaw = nil
        wraps = 0
        format = nil
        sps = nil
        pps = nil
        framesShown = 0
        subject = nil
        keyframesLooked = 0
        keyframesSeen = 0
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        decoderFormat = nil
    }

    func enqueue(_ nals: [Data], rtpTimestamp: UInt32) {
        let time = presentationTime(rtpTimestamp)
        if layer.status == .failed {
            layer.flush()
            onNeedsKeyframe?()
        }
        var picture: [Data] = []
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: if nal != sps { sps = nal; format = nil }
            case 8: if nal != pps { pps = nal; format = nil }
            case 9: break  // access unit delimiter
            default: picture.append(nal)
            }
        }
        if format == nil, let sps, let pps {
            format = Self.makeFormat(sps: sps, pps: pps)
            if let format {
                let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
                if size.width > 0, size.height > 0 { onSize?(size) }
            }
        }
        guard let format else {
            onNeedsKeyframe?()
            return
        }
        guard !picture.isEmpty, let sample = Self.makeSample(picture, format: format, time: time) else { return }
        layer.enqueue(sample)
        framesShown += 1
        if picture.contains(where: { ($0.first ?? 0) & 0x1F == 5 }) { lookForSubject(sample, format: format) }
    }

    /// Decodes a keyframe apart from the display layer, the first three and then every fifth, and
    /// finds the avatar in it.
    private func lookForSubject(_ sample: CMSampleBuffer, format: CMVideoFormatDescription) {
        keyframesSeen += 1
        guard keyframesLooked < 3 || keyframesSeen % 5 == 0 else { return }
        keyframesLooked += 1
        if decoder == nil || decoderFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            var session: VTDecompressionSession?
            guard VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
            ) == noErr, let session else { return }
            decoder = session
            decoderFormat = format
        }
        guard let decoder else { return }
        VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return }
            let found = MuseSubjectFraming.bounds(
                luma: base.assumingMemoryBound(to: UInt8.self),
                width: CVPixelBufferGetWidthOfPlane(image, 0), height: CVPixelBufferGetHeightOfPlane(image, 0),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            )
            guard let found else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let grown = self.subject.map { $0.union(found) } ?? found
                guard grown != self.subject else { return }
                self.subject = grown
                self.onSubject?(grown)
            }
        }
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    /// AVCC: each NAL unit after a 4-byte big-endian length, shown as soon as it decodes.
    /// The frame's time on the layer's clock, starting or restarting that clock when needed.
    private func presentationTime(_ raw: UInt32) -> CMTime {
        if let lastRaw, raw < lastRaw, lastRaw - raw > 0x8000_0000 { wraps += 1 }
        lastRaw = raw
        let time = CMTime(value: wraps << 32 | Int64(raw), timescale: 90_000)
        let target = CMTimeSubtract(time, CMTime(seconds: Self.delay, preferredTimescale: 90_000))
        if let timebase {
            // Far behind or far ahead of the clock (a stall, a restart): line up again.
            let lag = CMTimeGetSeconds(CMTimebaseGetTime(timebase)) - CMTimeGetSeconds(time)
            if lag > 1 || lag < -3 { CMTimebaseSetTime(timebase, time: target) }
        } else {
            var created: CMTimebase?
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                               timebaseOut: &created) == noErr, let created {
                CMTimebaseSetTime(created, time: target)
                CMTimebaseSetRate(created, rate: 1)
                layer.controlTimebase = created
                timebase = created
            }
        }
        return time
    }

    private static func makeSample(_ nals: [Data], format: CMVideoFormatDescription, time: CMTime) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            avcc.append(MuseSTUN.be32(UInt32(nal.count)))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        return sample
    }
}

/// Hosts the renderer's layer in SwiftUI.
final class MuseVideoLayerView: UIView {
    /// When both are known, the avatar inside the picture is framed to the view, not the picture.
    var subject: CGRect? { didSet { if subject != oldValue { setNeedsLayout() } } }
    var videoSize: CGSize? { didSet { if videoSize != oldValue { setNeedsLayout() } } }

    var renderer: MuseVideoRenderer? {
        didSet {
            oldValue?.layer.removeFromSuperlayer()
            if let renderer { layer.addSublayer(renderer.layer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let subject, let videoSize {
            renderer?.layer.videoGravity = .resize
            renderer?.layer.frame = MuseSubjectFraming.layerFrame(bounds: bounds.size, video: videoSize, subject: subject)
        } else {
            renderer?.layer.frame = bounds
        }
        CATransaction.commit()
    }
}
