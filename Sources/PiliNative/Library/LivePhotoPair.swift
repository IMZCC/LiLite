import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Create a paired JPEG and QuickTime movie. Only source media explicitly chosen
/// for saving enters this path; both temporary files share a per-export directory.
enum LivePhotoPair {
  static func save(still: URL, motion: URL) async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { throw GalleryPhotoPermission.denied }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (img, mov) = try await prepare(still: still, motion: motion, in: folder)
    try await PHPhotoLibrary.shared().performChanges {
      let item = PHAssetCreationRequest.forAsset()
      item.addResource(with: .photo, fileURL: img, options: nil)
      item.addResource(with: .pairedVideo, fileURL: mov, options: nil)
    }
  }
  static func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pili-live-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    return dir
  }
  static func prepare(still: URL, motion: URL, in folder: URL) async throws -> (URL, URL) {
    let img = folder.appendingPathComponent("photo.jpg")
    let mov = folder.appendingPathComponent("paired.mov")
    let id = UUID().uuidString
    try writeStill(still, to: img, id: id)
    do { try await pairVideo(motion, to: mov, id: id) } catch {
      try Task.checkCancellation()
      // Some codecs cannot be copied into a QuickTime movie. Transcode only
      // this clip, preserve the audio track, then add the same pair metadata.
      if FileManager.default.fileExists(atPath: mov.path) {
        try FileManager.default.removeItem(at: mov)
      }
      let normalized = folder.appendingPathComponent("compatible.mov")
      try await transcode(motion, to: normalized)
      try await pairVideo(normalized, to: mov, id: id)
    }
    try await validate(img, mov)
    try Task.checkCancellation()
    return (img, mov)
  }
  private static func writeStill(_ input: URL, to output: URL, id: String) throws {
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
      let dest = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ServiceError("无法读取实况封面") }
    var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    var maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
    maker["17"] = id
    props[kCGImagePropertyMakerAppleDictionary] = maker
    props[kCGImageDestinationLossyCompressionQuality] = 0.97
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ServiceError("无法写入实况封面") }
  }
  private static func transcode(_ url: URL, to output: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let e = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
      e.supportedFileTypes.contains(.mov)
    else { throw ServiceError("实况视频编码不受支持") }
    e.outputURL = output
    e.outputFileType = .mov
    await withTaskCancellationHandler(
      operation: { await withCheckedContinuation { c in e.exportAsynchronously { c.resume() } } },
      onCancel: { e.cancelExport() })
    guard e.status == .completed else { throw e.error ?? ServiceError("实况视频转码失败") }
  }
  private static func pairVideo(_ url: URL, to output: URL, id: String) async throws {
    let asset = AVURLAsset(url: url)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    let reader = try AVAssetReader(asset: asset)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else {
      throw ServiceError("实况文件中没有视频轨道")
    }
    let limit = try await video.load(.timeRange)
    guard limit.duration.seconds.isFinite, limit.duration.seconds > 0 else {
      throw ServiceError("实况视频时长无效")
    }
    var tracks = [video]
    if let a = try await asset.loadTracks(withMediaType: .audio).first { tracks.append(a) }
    var streams: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
    for track in tracks {
      let format = try await track.load(.formatDescriptions).first
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      out.alwaysCopiesSampleData = false
      let input = AVAssetWriterInput(
        mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
      if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
      guard reader.canAdd(out), writer.canAdd(input) else { throw ServiceError("无法复制实况音视频轨道") }
      reader.add(out)
      writer.add(input)
      streams.append((out, input))
    }
    let assetID = AVMutableMetadataItem()
    assetID.identifier = .quickTimeMetadataContentIdentifier
    assetID.value = id as NSString
    assetID.dataType = kCMMetadataBaseDataType_UTF8 as String
    writer.metadata = [assetID]
    let specs = [
      [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
          "mdta/com.apple.quicktime.still-image-time",
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
          kCMMetadataBaseDataType_SInt8 as String,
      ]
    ]
    var desc: CMFormatDescription?
    guard
      CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specs as CFArray, formatDescriptionOut: &desc) == noErr, let desc
    else { throw ServiceError("无法创建实况时间标记") }
    let mi = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mi)
    guard writer.canAdd(mi) else { throw ServiceError("无法写入实况时间标记") }
    writer.add(mi)
    defer {
      if reader.status == .reading { reader.cancelReading() }
      if writer.status == .writing { writer.cancelWriting() }
    }
    guard writer.startWriting(), reader.startReading() else {
      throw writer.error ?? reader.error ?? ServiceError("无法开始处理实况视频")
    }
    writer.startSession(atSourceTime: .zero)
    let marker = AVMutableMetadataItem()
    marker.keySpace = .quickTimeMetadata
    marker.key = "com.apple.quicktime.still-image-time" as NSString
    marker.dataType = kCMMetadataBaseDataType_SInt8 as String
    marker.value = NSNumber(value: Int8(0))
    let rate = try await video.load(.nominalFrameRate)
    let frame = CMTime(
      seconds: min(limit.duration.seconds, 1 / Double(rate > 0 ? rate : 30)),
      preferredTimescale: 60000)
    let half = CMTimeMultiplyByFloat64(limit.duration, multiplier: 0.5)
    let t = CMTimeAdd(limit.start, CMTimeMinimum(half, CMTimeSubtract(limit.duration, frame)))
    guard
      adaptor.append(
        AVTimedMetadataGroup(items: [marker], timeRange: .init(start: t, duration: frame)))
    else { throw writer.error ?? ServiceError("写入时间标记失败") }
    mi.markAsFinished()
    var open = Set(streams.indices)
    var lastProgress = ContinuousClock.now
    while !open.isEmpty {
      try Task.checkCancellation()
      guard writer.status == .writing, reader.status != .failed && reader.status != .cancelled
      else { throw writer.error ?? reader.error ?? ServiceError("复制音视频轨道失败") }
      var advanced = false
      for i in open.sorted() {
        let (out, input) = streams[i]
        guard input.isReadyForMoreMediaData else { continue }
        if let sample = out.copyNextSampleBuffer() {
          guard input.append(sample) else { throw writer.error ?? ServiceError("写入音视频帧失败") }
        } else {
          input.markAsFinished()
          open.remove(i)
        }
        advanced = true
      }
      if advanced {
        lastProgress = .now
      } else {
        guard lastProgress.duration(to: .now) < (.seconds(20)) else {
          throw ServiceError("处理实况视频超时")
        }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    guard reader.status == .completed else { throw reader.error ?? ServiceError("实况视频读取不完整") }
    await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
    guard writer.status == .completed else { throw writer.error ?? ServiceError("未能生成实况视频") }
  }
  private static func validate(_ jpg: URL, _ mov: URL) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      PHLivePhoto.request(
        withResourceFileURLs: [jpg, mov], placeholderImage: nil,
        targetSize: CGSize(width: 80, height: 80), contentMode: .aspectFit
      ) { photo, info in
        if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
        if let err = info[PHLivePhotoInfoErrorKey] as? Error {
          c.resume(throwing: err)
        } else if photo != nil {
          c.resume()
        } else {
          c.resume(throwing: ServiceError("系统未能识别实况照片"))
        }
      }
    }
  }
}
