import ARKit
import AVFoundation
import CoreMotion
import Flutter
import UIKit

private enum ArChannelContract {
  static let methodChannel = "unav/tracking/ar_method"
  static let eventChannel = "unav/tracking/ar_pose_stream"
  static let previewViewType = "unav/tracking/ar_preview_view"
  static let startSessionMethod = "startSession"
  static let stopSessionMethod = "stopSession"
  static let getCapabilitiesMethod = "getCapabilities"
  static let captureCurrentFrameMethod = "captureCurrentFrame"
  // Returns a dict with JPEG bytes + contemporaneous ARFrame pose + arTimestamp.
  // Used by TrialRecorder to align VPR queries with the ARKit pose stream.
  static let captureCurrentFrameWithPoseMethod = "captureCurrentFrameWithPose"
  static let updateOverlayMethod = "updateOverlay"
  static let clearOverlayMethod = "clearOverlay"
  static let backendKey = "backend"
  static let isSupportedKey = "isSupported"
  static let xKey = "x"
  static let yKey = "y"
  static let zKey = "z"
  static let headingKey = "heading"
  static let confidenceKey = "confidence"
  static let timestampKey = "timestampMillis"
  // Native ARFrame.timestamp (seconds, relative to system uptime).
  // Used to align pose stream rows with VPR query captures.
  static let arTimestampKey = "arTimestamp"
  static let worldXKey = "worldX"
  static let worldYKey = "worldY"
  static let worldZKey = "worldZ"
  // Camera orientation as full quaternion [qw, qx, qy, qz] in ARKit world frame.
  // Lets downstream code reconstruct any Euler representation without loss.
  static let quatWKey = "qw"
  static let quatXKey = "qx"
  static let quatYKey = "qy"
  static let quatZKey = "qz"
  static let trackingStateKey = "trackingState"
  static let gravityXKey = "gravityX"
  static let gravityYKey = "gravityY"
  static let gravityZKey = "gravityZ"
  static let interfaceRotationDegKey = "interfaceRotationDeg"
  // Keys used inside the captureCurrentFrameWithPose response dict.
  static let jpegBytesKey = "jpegBytes"
  static let pathPointsKey = "pathPoints"
  static let activePathPointsKey = "activePathPoints"
  static let futurePathPointsKey = "futurePathPoints"
  static let nextWaypointKey = "nextWaypoint"
  static let destinationKey = "destination"
  static let waypointPulsePeriodSecKey = "waypointPulsePeriodSec"
  static let waypointPulseActiveKey = "waypointPulseActive"
}

private enum SpatialAudioChannelContract {
  static let methodChannel = "unav/audio/spatial_method"
  static let getCapabilitiesMethod = "getCapabilities"
  static let playCueMethod = "playCue"
  static let playStereoAssetMethod = "playStereoAsset"
  static let primeOffRouteLoopMethod = "primeOffRouteLoop"
  static let updateOffRouteAlertMethod = "updateOffRouteAlert"
  static let stopOffRouteAlertMethod = "stopOffRouteAlert"
  static let supportsSpatialKey = "supportsSpatial"
  static let supportsStereoPanKey = "supportsStereoPan"
  static let isMonoAudioEnabledKey = "isMonoAudioEnabled"
  static let hasHeadphonesConnectedKey = "hasHeadphonesConnected"
  static let cueTypeKey = "cueType"
  static let assetPathKey = "assetPath"
  static let sideKey = "side"
  static let severityKey = "severity"
  static let headingErrorDegKey = "headingErrorDeg"
  static let relativeAngleDegKey = "relativeAngleDeg"
  static let sourceDistanceMetersKey = "sourceDistanceMeters"
  static let distanceToWaypointMetersKey = "distanceToWaypointMeters"
  static let volumeKey = "volume"
  static let rateKey = "rate"
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let enableNativeHrtfProbeApp = false
  private lazy var flutterEngine = FlutterEngine(name: "unav_main_engine")
  private let arTrackingBridge = IOSArTrackingBridge()
  private let spatialAudioBridge = IOSSpatialAudioBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if enableNativeHrtfProbeApp {
      let probeViewController = HRTFProbeViewController()
      window = UIWindow(frame: UIScreen.main.bounds)
      window?.rootViewController = probeViewController
      window?.makeKeyAndVisible()
      return true
    }

    let started = flutterEngine.run()
    if started {
      GeneratedPluginRegistrant.register(with: flutterEngine)
      if let registrar = flutterEngine.registrar(forPlugin: "UNavArPreview") {
        arTrackingBridge.register(with: flutterEngine.binaryMessenger, registrar: registrar)
      }
      if let registrar = flutterEngine.registrar(forPlugin: "UNavSpatialAudio") {
        spatialAudioBridge.register(with: flutterEngine.binaryMessenger, registrar: registrar)
      }
    }

    let flutterViewController = FlutterViewController(
      engine: flutterEngine,
      nibName: nil,
      bundle: nil
    )

    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = flutterViewController
    window?.makeKeyAndVisible()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

private final class HRTFProbeViewController: UIViewController {
  private enum ProbeStage: Int {
    case engine2D = 0
    case environment = 1
    case hrtf = 2

    var title: String {
      switch self {
      case .engine2D: return "Engine 2D"
      case .environment: return "Environment"
      case .hrtf: return "HRTF"
      }
    }
  }

  private final class ProbeAudioLab {
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var environmentNode: AVAudioEnvironmentNode?
    private var playerNode: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var currentStage: ProbeStage = .engine2D

    func start(stage: ProbeStage, relativeAngleDeg: Double, sourceDistanceMeters: Double) throws {
      stop()
      try configureSession()
      currentStage = stage

      let engine = AVAudioEngine()
      let playerNode = AVAudioPlayerNode()
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: session.sampleRate,
        channels: 1,
        interleaved: false
      )!
      let outputFormat = engine.outputNode.inputFormat(forBus: 0)
      let buffer = try makeLoopBuffer(format: monoFormat)

      engine.attach(playerNode)

      switch stage {
      case .engine2D:
        do {
          engine.connect(playerNode, to: engine.mainMixerNode, format: monoFormat)
        } catch {
          throw NSError(
            domain: "HRTFProbe",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "2D connect failed: \(error.localizedDescription)"]
          )
        }
      case .environment, .hrtf:
        let environmentNode = AVAudioEnvironmentNode()
        engine.attach(environmentNode)
        do {
          engine.connect(playerNode, to: environmentNode, format: monoFormat)
          engine.connect(environmentNode, to: engine.mainMixerNode, format: outputFormat)
        } catch {
          throw NSError(
            domain: "HRTFProbe",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "3D connect failed: \(error.localizedDescription)"]
          )
        }
        environmentNode.outputVolume = 1.0
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(
          yaw: 0,
          pitch: 0,
          roll: 0
        )
        playerNode.renderingAlgorithm =
          stage == .hrtf ? .HRTFHQ : .equalPowerPanning
        playerNode.reverbBlend = stage == .hrtf ? 18 : 0
        self.environmentNode = environmentNode
      }

      engine.prepare()
      do {
        try engine.start()
      } catch {
        throw NSError(
          domain: "HRTFProbe",
          code: 23,
          userInfo: [NSLocalizedDescriptionKey: "Engine start failed: \(error.localizedDescription)"]
        )
      }

      playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
      playerNode.volume = 0.92
      playerNode.play()

      self.engine = engine
      self.playerNode = playerNode
      self.buffer = buffer
      updateSource(relativeAngleDeg: relativeAngleDeg, sourceDistanceMeters: sourceDistanceMeters)
    }

    func stop() {
      playerNode?.stop()
      engine?.stop()
      environmentNode = nil
      playerNode = nil
      engine = nil
    }

    func updateListenerYawDegrees(_ yawDegrees: Double) {
      environmentNode?.listenerAngularOrientation = AVAudio3DAngularOrientation(
        yaw: Float(-yawDegrees),
        pitch: 0,
        roll: 0
      )
    }

    func updateSource(relativeAngleDeg: Double, sourceDistanceMeters: Double) {
      guard let playerNode else { return }
      let lateralBoost = currentStage == .hrtf ? 1.35 : 1.0
      let effectiveAngleDeg = max(-85.0, min(85.0, relativeAngleDeg * lateralBoost))
      let theta = effectiveAngleDeg * .pi / 180.0
      let distance = max(0.8, min(6.0, sourceDistanceMeters))
      let x = Float(sin(theta) * distance)
      let z = Float(-cos(theta) * distance)
      playerNode.position = AVAudio3DPoint(x: x, y: 0.0, z: z)
    }

    private func configureSession() throws {
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers]
      )
      try session.setPreferredSampleRate(48_000)
      try session.setActive(true)
    }

    private func makeLoopBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
      if let buffer, buffer.format.sampleRate == format.sampleRate {
        return buffer
      }
      let durationSeconds = 1.0
      let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      ) else {
        throw NSError(
          domain: "HRTFProbe",
          code: 10,
          userInfo: [NSLocalizedDescriptionKey: "Unable to allocate mono PCM buffer."]
        )
      }
      buffer.frameLength = frameCount
      guard let channelData = buffer.floatChannelData?[0] else {
        throw NSError(
          domain: "HRTFProbe",
          code: 11,
          userInfo: [NSLocalizedDescriptionKey: "Unable to access mono channel data."]
        )
      }

      let sampleRate = format.sampleRate
      let burstStarts = [0.0, 0.28, 0.56, 0.84]
      let burstDuration = 0.07
      let baseFrequency = 150.0

      for frame in 0..<Int(frameCount) {
        let time = Double(frame) / sampleRate
        var sample = 0.0
        for burstStart in burstStarts {
          let dt = time - burstStart
          if dt >= 0 && dt <= burstDuration {
            let envelope = exp(-dt * 26.0)
            let tone = sin(2.0 * .pi * baseFrequency * dt)
            let overtone = 0.40 * sin(2.0 * .pi * baseFrequency * 2.1 * dt)
            sample += (tone + overtone) * envelope
          }
        }
        channelData[frame] = Float(sample * 0.55)
      }

      self.buffer = buffer
      return buffer
    }
  }

  private let audioLab = ProbeAudioLab()
  private let motionManager = CMMotionManager()
  private var baseYawRadians: Double?
  private var currentSourceAngleDeg = 45.0
  private var currentWaypointDistanceMeters = 6.0
  private var currentStage: ProbeStage = .engine2D

  private let titleLabel = UILabel()
  private let statusLabel = UILabel()
  private let yawLabel = UILabel()
  private let sourceLabel = UILabel()

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1.0)
    setupUI()

    startMotionUpdates()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startCurrentStage()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    motionManager.stopDeviceMotionUpdates()
    audioLab.stop()
  }

  private func setupUI() {
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "UNav HRTF Probe"
    titleLabel.font = UIFont.boldSystemFont(ofSize: 28)
    titleLabel.textColor = .white

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
    statusLabel.numberOfLines = 0

    yawLabel.translatesAutoresizingMaskIntoConstraints = false
    yawLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
    yawLabel.textColor = UIColor(red: 0.68, green: 0.92, blue: 1.0, alpha: 1.0)
    yawLabel.text = "Yaw: 0 deg"

    sourceLabel.translatesAutoresizingMaskIntoConstraints = false
    sourceLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
    sourceLabel.textColor = UIColor(red: 0.75, green: 1.0, blue: 0.82, alpha: 1.0)

    let stack = UIStackView(arrangedSubviews: [
      titleLabel,
      statusLabel,
      yawLabel,
      sourceLabel,
      makeStageControl(),
      makeButtonRow(title: "Source", buttons: [
        makeSourceButton("Left", angle: -90),
        makeSourceButton("Front", angle: 0),
        makeSourceButton("Right", angle: 90),
        makeSourceButton("Back", angle: 180),
      ]),
      makeButtonRow(title: "Waypoint Distance", buttons: [
        makeDistanceButton("3m", distance: 3.0),
        makeDistanceButton("6m", distance: 6.0),
        makeDistanceButton("7m", distance: 7.0),
        makeDistanceButton("10m", distance: 10.0),
      ]),
      makeActionButton("Recenter Yaw", action: #selector(recenterYaw)),
    ])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 18

    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
    ])

    updateSourceLabel()
  }

  private func makeStageControl() -> UIView {
    let label = UILabel()
    label.text = "Stage"
    label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    label.textColor = UIColor.white.withAlphaComponent(0.7)

    let control = UISegmentedControl(items: [
      ProbeStage.engine2D.title,
      ProbeStage.environment.title,
      ProbeStage.hrtf.title,
    ])
    control.selectedSegmentIndex = currentStage.rawValue
    control.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    if #available(iOS 13.0, *) {
      control.selectedSegmentTintColor = UIColor(red: 0.16, green: 0.36, blue: 0.58, alpha: 1.0)
    }
    control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    control.setTitleTextAttributes(
      [.foregroundColor: UIColor.white.withAlphaComponent(0.8)],
      for: .normal
    )
    control.addTarget(self, action: #selector(handleStageChanged(_:)), for: .valueChanged)

    let container = UIStackView(arrangedSubviews: [label, control])
    container.axis = .vertical
    container.spacing = 8
    return container
  }

  private func makeButtonRow(title: String, buttons: [UIButton]) -> UIStackView {
    let rowLabel = UILabel()
    rowLabel.text = title
    rowLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    rowLabel.textColor = UIColor.white.withAlphaComponent(0.7)

    let buttonsRow = UIStackView(arrangedSubviews: buttons)
    buttonsRow.axis = .horizontal
    buttonsRow.spacing = 10
    buttonsRow.distribution = .fillEqually

    let container = UIStackView(arrangedSubviews: [rowLabel, buttonsRow])
    container.axis = .vertical
    container.spacing = 8
    return container
  }

  private func makeActionButton(_ title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    button.tintColor = .white
    button.backgroundColor = UIColor(red: 0.16, green: 0.36, blue: 0.58, alpha: 1.0)
    button.layer.cornerRadius = 12
    button.heightAnchor.constraint(equalToConstant: 46).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func makeSourceButton(_ title: String, angle: Double) -> UIButton {
    let button = makeActionButton(title, action: #selector(handleSourceButton(_:)))
    button.tag = Int(angle)
    return button
  }

  private func makeDistanceButton(_ title: String, distance: Double) -> UIButton {
    let button = makeActionButton(title, action: #selector(handleDistanceButton(_:)))
    button.accessibilityIdentifier = "\(distance)"
    return button
  }

  private func startMotionUpdates() {
    guard motionManager.isDeviceMotionAvailable else {
      statusLabel.text = "Device motion unavailable"
      return
    }

    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      guard let self, let motion else { return }
      let yaw = motion.attitude.yaw
      if self.baseYawRadians == nil {
        self.baseYawRadians = yaw
      }
      let baseYaw = self.baseYawRadians ?? yaw
      let relativeYawDeg = (yaw - baseYaw) * 180.0 / .pi
      self.audioLab.updateListenerYawDegrees(relativeYawDeg)
      self.yawLabel.text = String(format: "Yaw: %.1f deg", relativeYawDeg)
    }
  }

  private func updateSourcePosition() {
    audioLab.updateSource(
      relativeAngleDeg: currentSourceAngleDeg,
      sourceDistanceMeters: computedSourceDistanceMeters
    )
    updateSourceLabel()
  }

  private func startCurrentStage() {
    do {
      try audioLab.start(
        stage: currentStage,
        relativeAngleDeg: currentSourceAngleDeg,
        sourceDistanceMeters: computedSourceDistanceMeters
      )
      statusLabel.text = "Stage: \(currentStage.title)"
      updateSourcePosition()
    } catch {
      statusLabel.text = "Audio init failed (\(currentStage.title)): \(error.localizedDescription)"
    }
  }

  private func updateSourceLabel() {
    sourceLabel.text = String(
      format: "Source: %.0f deg | waypoint %.1f m -> source %.1f m",
      currentSourceAngleDeg,
      currentWaypointDistanceMeters,
      computedSourceDistanceMeters
    )
  }

  private var computedSourceDistanceMeters: Double {
    min(currentWaypointDistanceMeters, 6.0)
  }

  @objc private func recenterYaw() {
    baseYawRadians = nil
  }

  @objc private func handleStageChanged(_ sender: UISegmentedControl) {
    guard let stage = ProbeStage(rawValue: sender.selectedSegmentIndex) else { return }
    currentStage = stage
    startCurrentStage()
  }

  @objc private func handleSourceButton(_ sender: UIButton) {
    currentSourceAngleDeg = Double(sender.tag)
    updateSourcePosition()
  }

  @objc private func handleDistanceButton(_ sender: UIButton) {
    guard
      let text = sender.accessibilityIdentifier,
      let distance = Double(text)
    else { return }
    currentWaypointDistanceMeters = distance
    updateSourcePosition()
  }
}

private final class IOSArTrackingBridge: NSObject, FlutterStreamHandler, ARSessionDelegate {
  let session = ARSession()

  private let ciContext = CIContext()
  private var eventSink: FlutterEventSink?
  private var isSessionRunning = false
  private var latestFrame: ARFrame?
  private let previewViews = NSHashTable<ARSCNView>.weakObjects()
  private let overlayRootNode = SCNNode()

  override init() {
    super.init()
    session.delegate = self
    overlayRootNode.name = "unav_overlay_root"
  }

  func register(with messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: ArChannelContract.methodChannel,
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: ArChannelContract.eventChannel,
      binaryMessenger: messenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "bridge_unavailable", message: nil, details: nil))
        return
      }

      switch call.method {
      case ArChannelContract.getCapabilitiesMethod:
        result([
          ArChannelContract.backendKey: "iosArKit",
          ArChannelContract.isSupportedKey: ARWorldTrackingConfiguration.isSupported,
        ])
      case ArChannelContract.startSessionMethod:
        self.startSession(result: result)
      case ArChannelContract.stopSessionMethod:
        self.stopSession()
        result(nil)
      case ArChannelContract.captureCurrentFrameMethod:
        self.captureCurrentFrame(result: result)
      case ArChannelContract.captureCurrentFrameWithPoseMethod:
        self.captureCurrentFrameWithPose(result: result)
      case ArChannelContract.updateOverlayMethod:
        self.updateOverlay(arguments: call.arguments)
        result(nil)
      case ArChannelContract.clearOverlayMethod:
        self.clearOverlay()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    eventChannel.setStreamHandler(self)
    registrar.register(IOSArPreviewFactory(bridge: self), withId: ArChannelContract.previewViewType)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    latestFrame = frame
    guard let eventSink else { return }

    let transform = frame.camera.transform
    let translation = transform.columns.3
    let x = Double(translation.x)
    let y = Double(-translation.z)
    let z = Double(translation.y)
    let heading = yawDegrees(from: transform)
    let gravity = frame.camera.transform.columns.1
    let interfaceRotationDeg = currentInterfaceRotationDegrees()
    // Full camera orientation as a quaternion (lossless; downstream can reconstruct
    // any Euler representation it wants).
    let quat = simd_quatf(transform)

    eventSink([
      ArChannelContract.xKey: x,
      ArChannelContract.yKey: y,
      ArChannelContract.zKey: z,
      ArChannelContract.headingKey: heading,
      ArChannelContract.confidenceKey: confidenceValue(for: frame.camera.trackingState),
      ArChannelContract.timestampKey: Int(Date().timeIntervalSince1970 * 1000.0),
      // Native ARFrame timestamp (seconds, CACurrentMediaTime domain). This is
      // what lets TrialRecorder align VPR query captures with a specific row of
      // the pose ndjson.
      ArChannelContract.arTimestampKey: frame.timestamp,
      ArChannelContract.worldXKey: Double(translation.x),
      ArChannelContract.worldYKey: Double(translation.y),
      ArChannelContract.worldZKey: Double(translation.z),
      ArChannelContract.quatWKey: Double(quat.real),
      ArChannelContract.quatXKey: Double(quat.imag.x),
      ArChannelContract.quatYKey: Double(quat.imag.y),
      ArChannelContract.quatZKey: Double(quat.imag.z),
      ArChannelContract.trackingStateKey: trackingStateName(for: frame.camera.trackingState),
      ArChannelContract.gravityXKey: Double(gravity.x),
      ArChannelContract.gravityYKey: Double(gravity.y),
      ArChannelContract.gravityZKey: Double(gravity.z),
      ArChannelContract.interfaceRotationDegKey: interfaceRotationDeg,
    ])
  }

  private func trackingStateName(for state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal:
      return "normal"
    case .limited:
      return "limited"
    case .notAvailable:
      return "notAvailable"
    }
  }

  private func startSession(result: FlutterResult) {
    guard ARWorldTrackingConfiguration.isSupported else {
      result(
        FlutterError(
          code: "arkit_unsupported",
          message: "ARKit world tracking is unavailable on this device.",
          details: nil
        )
      )
      return
    }

    let configuration = ARWorldTrackingConfiguration()
    configuration.worldAlignment = .gravity
    session.run(configuration, options: isSessionRunning ? [] : [.resetTracking, .removeExistingAnchors])
    isSessionRunning = true
    result(nil)
  }

  private func stopSession() {
    guard isSessionRunning else { return }
    session.pause()
    isSessionRunning = false
  }

  private func captureCurrentFrame(result: FlutterResult) {
    guard let frame = latestFrame else {
      result(
        FlutterError(
          code: "frame_unavailable",
          message: "No AR frame available for relocalization.",
          details: nil
        )
      )
      return
    }

    let image = CIImage(cvPixelBuffer: frame.capturedImage)
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      result(
        FlutterError(
          code: "frame_conversion_failed",
          message: "Unable to convert AR frame to image.",
          details: nil
        )
      )
      return
    }

    let orientation = uiImageOrientation(for: currentInterfaceOrientation())
    let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
    guard let jpegData = uiImage.jpegData(compressionQuality: 0.95) else {
      result(
        FlutterError(
          code: "frame_encoding_failed",
          message: "Unable to encode AR frame as JPEG.",
          details: nil
        )
      )
      return
    }

    result(FlutterStandardTypedData(bytes: jpegData))
  }

  // Like captureCurrentFrame, but ALSO returns the contemporaneous ARFrame
  // pose (position + quaternion) and the native ARFrame.timestamp. Used by
  // TrialRecorder to index VPR query captures into the pose ndjson stream.
  //
  // Response dictionary keys:
  //   jpegBytes        FlutterStandardTypedData (JPEG)
  //   arTimestamp      Double (ARFrame.timestamp, seconds)
  //   timestampMillis  Int (wall clock at capture, for convenience)
  //   x, y, z          Double (project-space position, same convention as pose stream)
  //   worldX/Y/Z       Double (raw ARKit translation, matches pose stream)
  //   qw, qx, qy, qz   Double (camera orientation quaternion)
  //   heading          Double (yaw degrees)
  //   trackingState    String ("normal" | "limited" | "notAvailable")
  //   interfaceRotationDeg Double
  private func captureCurrentFrameWithPose(result: FlutterResult) {
    guard let frame = latestFrame else {
      result(
        FlutterError(
          code: "frame_unavailable",
          message: "No AR frame available.",
          details: nil
        )
      )
      return
    }

    let image = CIImage(cvPixelBuffer: frame.capturedImage)
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      result(
        FlutterError(
          code: "frame_conversion_failed",
          message: "Unable to convert AR frame to image.",
          details: nil
        )
      )
      return
    }

    let orientation = uiImageOrientation(for: currentInterfaceOrientation())
    let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
    guard let jpegData = uiImage.jpegData(compressionQuality: 0.95) else {
      result(
        FlutterError(
          code: "frame_encoding_failed",
          message: "Unable to encode AR frame as JPEG.",
          details: nil
        )
      )
      return
    }

    let transform = frame.camera.transform
    let translation = transform.columns.3
    let quat = simd_quatf(transform)
    let heading = yawDegrees(from: transform)
    let interfaceRotationDeg = currentInterfaceRotationDegrees()

    let response: [String: Any] = [
      ArChannelContract.jpegBytesKey: FlutterStandardTypedData(bytes: jpegData),
      ArChannelContract.arTimestampKey: frame.timestamp,
      ArChannelContract.timestampKey: Int(Date().timeIntervalSince1970 * 1000.0),
      ArChannelContract.xKey: Double(translation.x),
      ArChannelContract.yKey: Double(-translation.z),
      ArChannelContract.zKey: Double(translation.y),
      ArChannelContract.worldXKey: Double(translation.x),
      ArChannelContract.worldYKey: Double(translation.y),
      ArChannelContract.worldZKey: Double(translation.z),
      ArChannelContract.quatWKey: Double(quat.real),
      ArChannelContract.quatXKey: Double(quat.imag.x),
      ArChannelContract.quatYKey: Double(quat.imag.y),
      ArChannelContract.quatZKey: Double(quat.imag.z),
      ArChannelContract.headingKey: heading,
      ArChannelContract.trackingStateKey: trackingStateName(for: frame.camera.trackingState),
      ArChannelContract.interfaceRotationDegKey: interfaceRotationDeg,
    ]

    result(response)
  }

  private func yawDegrees(from transform: simd_float4x4) -> Double {
    let cameraForward = SIMD3<Float>(
      -transform.columns.2.x,
      -transform.columns.2.y,
      -transform.columns.2.z
    )
    let planarX = Double(cameraForward.x)
    let planarY = Double(-cameraForward.z)
    let heading = atan2(planarY, planarX) * 180.0 / .pi
    return normalizedDegrees(heading)
  }

  private func normalizedDegrees(_ value: Double) -> Double {
    var normalized = value.truncatingRemainder(dividingBy: 360.0)
    if normalized < 0 {
      normalized += 360.0
    }
    return normalized
  }

  private func confidenceValue(for trackingState: ARCamera.TrackingState) -> Double {
    switch trackingState {
    case .normal:
      return 1.0
    case .limited:
      return 0.5
    case .notAvailable:
      return 0.0
    }
  }

  private func currentInterfaceRotationDegrees() -> Double {
    switch currentInterfaceOrientation() {
    case .portrait:
      return 0
    case .landscapeLeft:
      return 90
    case .landscapeRight:
      return -90
    case .portraitUpsideDown:
      return 180
    default:
      return 0
    }
  }

  private func currentInterfaceOrientation() -> UIInterfaceOrientation {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?
        .interfaceOrientation ?? .portrait
    }
    return UIApplication.shared.statusBarOrientation
  }

  private func uiImageOrientation(for orientation: UIInterfaceOrientation) -> UIImage.Orientation {
    switch orientation {
    case .portrait:
      return .right
    case .landscapeLeft:
      return .up
    case .landscapeRight:
      return .down
    case .portraitUpsideDown:
      return .left
    default:
      return .right
    }
  }

  func attachPreviewView(_ sceneView: ARSCNView) {
    previewViews.add(sceneView)
    if overlayRootNode.parent == nil {
      sceneView.scene.rootNode.addChildNode(overlayRootNode)
    }
  }

  private func clearOverlay() {
    overlayRootNode.childNodes.forEach { $0.removeFromParentNode() }
  }

  private func updateOverlay(arguments: Any?) {
    guard
      let args = arguments as? [String: Any]
    else {
      clearOverlay()
      return
    }

    previewViews.allObjects.forEach { sceneView in
      if overlayRootNode.parent !== sceneView.scene.rootNode {
        overlayRootNode.removeFromParentNode()
        sceneView.scene.rootNode.addChildNode(overlayRootNode)
      }
    }

    clearOverlay()

    let activePathPoints =
      (args[ArChannelContract.activePathPointsKey] as? [[String: Any]] ?? [])
      .compactMap { point(from: $0) }
    let futurePathPoints =
      (args[ArChannelContract.futurePathPointsKey] as? [[String: Any]] ?? [])
      .compactMap { point(from: $0) }

    if activePathPoints.count >= 2 {
      for index in 0..<(activePathPoints.count - 1) {
        let segment = buildPathSegmentNode(
          from: activePathPoints[index],
          to: activePathPoints[index + 1],
          radius: 0.032,
          color: UIColor.systemTeal,
          opacity: 0.96
        )
        overlayRootNode.addChildNode(segment)
      }
      overlayRootNode.addChildNode(
        buildFlowBeamNode(
          from: activePathPoints[0],
          to: activePathPoints[1],
          color: UIColor.systemTeal
        )
      )
    }

    if futurePathPoints.count >= 2 {
      for index in 0..<(futurePathPoints.count - 1) {
        let segment = buildPathSegmentNode(
          from: futurePathPoints[index],
          to: futurePathPoints[index + 1],
          radius: 0.018,
          color: UIColor.systemBlue,
          opacity: 0.42
        )
        overlayRootNode.addChildNode(segment)
      }
    }

    let pulsePeriod =
      (args[ArChannelContract.waypointPulsePeriodSecKey] as? NSNumber)?.doubleValue ?? 1.0
    let pulseActive = args[ArChannelContract.waypointPulseActiveKey] as? Bool ?? false

    if let nextWaypointArgs = args[ArChannelContract.nextWaypointKey] as? [String: Any],
       let nextPoint = point(from: nextWaypointArgs) {
      overlayRootNode.addChildNode(
        buildMarkerNode(
          at: nextPoint,
          radius: 0.08,
          color: UIColor.systemTeal,
          pulsePeriod: pulsePeriod,
          pulseActive: pulseActive
        )
      )
    }

    if let destinationArgs = args[ArChannelContract.destinationKey] as? [String: Any],
       let destinationPoint = point(from: destinationArgs) {
      overlayRootNode.addChildNode(
        buildWaypointRingNode(
          at: destinationPoint,
          radius: 0.28,
          color: UIColor.systemOrange
        )
      )
      overlayRootNode.addChildNode(
        buildMarkerNode(
          at: destinationPoint,
          radius: 0.11,
          color: UIColor.systemOrange
        )
      )
    }
  }

  private func point(from dictionary: [String: Any]) -> SCNVector3? {
    guard
      let x = (dictionary[ArChannelContract.xKey] as? NSNumber)?.floatValue,
      let y = (dictionary[ArChannelContract.yKey] as? NSNumber)?.floatValue,
      let z = (dictionary[ArChannelContract.zKey] as? NSNumber)?.floatValue
    else {
      return nil
    }

    return SCNVector3(x, y, z)
  }

  private func buildMarkerNode(
    at point: SCNVector3,
    radius: CGFloat,
    color: UIColor,
    pulsePeriod: TimeInterval? = nil,
    pulseActive: Bool = false
  ) -> SCNNode {
    let sphere = SCNSphere(radius: radius)
    sphere.firstMaterial?.diffuse.contents = color
    sphere.firstMaterial?.emission.contents = color.withAlphaComponent(0.35)

    let node = SCNNode(geometry: sphere)
    node.position = SCNVector3(point.x, point.y + Float(radius), point.z)
    if pulseActive, let pulsePeriod {
      applyHeartbeatAppearance(
        to: node,
        color: color,
        period: pulsePeriod
      )
    }
    return node
  }

  private func applyHeartbeatAppearance(
    to node: SCNNode,
    color: UIColor,
    period: TimeInterval
  ) {
    let clampedPeriod = max(0.28, min(2.2, period))
    let time = CACurrentMediaTime().truncatingRemainder(dividingBy: clampedPeriod)
    let phase = time / clampedPeriod

    let pulse: Double
    if phase < 0.18 {
      pulse = phase / 0.18
    } else if phase < 0.5 {
      let local = (phase - 0.18) / 0.32
      pulse = 1.0 - (local * 0.85)
    } else {
      let local = (phase - 0.5) / 0.5
      pulse = 0.15 * (1.0 - local)
    }

    let scale = Float(1.0 + (0.32 * pulse))
    node.scale = SCNVector3(scale, scale, scale)
    node.opacity = CGFloat(0.82 + (0.18 * pulse))

    if let material = node.geometry?.firstMaterial {
      material.emission.contents = color.withAlphaComponent(CGFloat(0.22 + (0.68 * pulse)))
      material.diffuse.contents = color.withAlphaComponent(CGFloat(0.84 + (0.16 * pulse)))
    }
  }

  private func buildWaypointRingNode(
    at point: SCNVector3,
    radius: CGFloat,
    color: UIColor
  ) -> SCNNode {
    let ring = SCNTorus(ringRadius: radius, pipeRadius: max(0.012, radius * 0.12))
    ring.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.9)
    ring.firstMaterial?.emission.contents = color.withAlphaComponent(0.28)

    let node = SCNNode(geometry: ring)
    node.position = SCNVector3(point.x, point.y + 0.015, point.z)
    node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
    return node
  }

  private func buildFlowBeamNode(
    from start: SCNVector3,
    to end: SCNVector3,
    color: UIColor
  ) -> SCNNode {
    let container = SCNNode()
    let arrowCount = 3

    for index in 0..<arrowCount {
      let cone = SCNCone(topRadius: 0.0, bottomRadius: 0.045, height: 0.11)
      cone.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.95)
      cone.firstMaterial?.emission.contents = color.withAlphaComponent(0.45)

      let arrow = SCNNode(geometry: cone)
      arrow.opacity = 0.0
      arrow.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
      container.addChildNode(arrow)

      let delay = Double(index) * 0.28
      let action = arrowFlowAction(
        from: start,
        to: end,
        delay: delay
      )
      arrow.runAction(action)
    }

    return container
  }

  private func arrowFlowAction(
    from start: SCNVector3,
    to end: SCNVector3,
    delay: TimeInterval
  ) -> SCNAction {
    let liftedStart = SCNVector3(start.x, start.y + 0.09, start.z)
    let liftedEnd = SCNVector3(end.x, end.y + 0.09, end.z)
    let mid = SCNVector3(
      (liftedStart.x + liftedEnd.x) / 2.0,
      (liftedStart.y + liftedEnd.y) / 2.0,
      (liftedStart.z + liftedEnd.z) / 2.0
    )

    let orient = SCNAction.run { node in
      node.position = liftedStart
      node.look(at: liftedEnd)
      node.eulerAngles.x += Float.pi / 2
    }
    let fadeIn = SCNAction.fadeOpacity(to: 0.95, duration: 0.12)
    let moveToMid = SCNAction.move(to: mid, duration: 0.42)
    let moveToEnd = SCNAction.move(to: liftedEnd, duration: 0.42)
    let fadeOut = SCNAction.fadeOut(duration: 0.16)
    let reset = SCNAction.run { node in
      node.opacity = 0.0
      node.position = liftedStart
    }
    let sequence = SCNAction.sequence([
      .wait(duration: delay),
      orient,
      .group([fadeIn, moveToMid]),
      .group([moveToEnd, fadeOut]),
      .wait(duration: 0.12),
      reset,
    ])

    return .repeatForever(sequence)
  }

  private func buildPathSegmentNode(
    from start: SCNVector3,
    to end: SCNVector3,
    radius: CGFloat,
    color: UIColor,
    opacity: CGFloat
  ) -> SCNNode {
    let liftedStart = SCNVector3(start.x, start.y + 0.03, start.z)
    let liftedEnd = SCNVector3(end.x, end.y + 0.03, end.z)
    let dx = liftedEnd.x - liftedStart.x
    let dy = liftedEnd.y - liftedStart.y
    let dz = liftedEnd.z - liftedStart.z
    let length = sqrt((dx * dx) + (dy * dy) + (dz * dz))
    let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
    cylinder.firstMaterial?.diffuse.contents = color.withAlphaComponent(opacity)
    cylinder.firstMaterial?.emission.contents = color.withAlphaComponent(opacity * 0.25)

    let node = SCNNode(geometry: cylinder)
    node.position = SCNVector3(
      (liftedStart.x + liftedEnd.x) / 2.0,
      (liftedStart.y + liftedEnd.y) / 2.0,
      (liftedStart.z + liftedEnd.z) / 2.0
    )
    node.eulerAngles = eulerAnglesForCylinder(from: liftedStart, to: liftedEnd)
    return node
  }

  private func eulerAnglesForCylinder(from start: SCNVector3, to end: SCNVector3) -> SCNVector3 {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let dz = end.z - start.z
    let horizontal = sqrt((dx * dx) + (dz * dz))
    let pitch = Float.pi / 2 - atan2(dy, horizontal)
    let yaw = atan2(dx, dz)
    return SCNVector3(pitch, yaw, 0)
  }
}

private final class IOSArPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let bridge: IOSArTrackingBridge

  init(bridge: IOSArTrackingBridge) {
    self.bridge = bridge
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    IOSArPreviewPlatformView(frame: frame, bridge: bridge)
  }
}

private final class IOSArPreviewPlatformView: NSObject, FlutterPlatformView {
  private let sceneView: ARSCNView

  init(frame: CGRect, bridge: IOSArTrackingBridge) {
    sceneView = ARSCNView(frame: frame)
    super.init()

    sceneView.automaticallyUpdatesLighting = false
    sceneView.rendersContinuously = true
    sceneView.backgroundColor = .black
    sceneView.scene = SCNScene()
    sceneView.session = bridge.session
    bridge.attachPreviewView(sceneView)
  }

  func view() -> UIView {
    sceneView
  }
}

private final class IOSSpatialAudioBridge: NSObject {
  private let engine = AVAudioEngine()
  private let environmentNode = AVAudioEnvironmentNode()
  private let eventPlayer = AVAudioPlayerNode()
  private let offRoutePlayer = AVAudioPlayerNode()
  private var spatialInputFormat: AVAudioFormat?
  private var stereoPlayer: AVAudioPlayer?
  private var lookupAssetKey: ((String) -> String)?
  private var offRouteSide = "center"
  private var offRouteSeverity = 0.0
  private var offRouteHeadingErrorDeg = 180.0
  private var relativeAngleDeg = 0.0
  private var sourceDistanceMeters = 2.0
  private var distanceToWaypointMeters = 6.0
  private var offRoutePulseTimer: Timer?
  private var isPrimedSilently = false
  private var isInitialized = false

  func startProbe(relativeAngleDeg: Double, distanceMeters: Double) throws {
    try ensureInitialized()
    offRouteSeverity = 1.0
    offRouteHeadingErrorDeg = max(12.0, abs(relativeAngleDeg))
    self.relativeAngleDeg = relativeAngleDeg
    self.sourceDistanceMeters = distanceMeters
    self.distanceToWaypointMeters = 0.8
    let position = directionalPosition(
      relativeAngleDeg: relativeAngleDeg,
      distanceMeters: distanceMeters
    )
    playAsset("assets/sounds/offroute_drum.wav", on: offRoutePlayer, position: position, volume: 0.92)
  }

  func updateProbe(relativeAngleDeg: Double, distanceMeters: Double) {
    try? ensureInitialized()
    offRouteSeverity = 1.0
    offRouteHeadingErrorDeg = max(12.0, abs(relativeAngleDeg))
    self.relativeAngleDeg = relativeAngleDeg
    self.sourceDistanceMeters = distanceMeters
    let position = directionalPosition(
      relativeAngleDeg: relativeAngleDeg,
      distanceMeters: distanceMeters
    )
    offRoutePlayer.position = position
    if !offRoutePlayer.isPlaying {
      playAsset("assets/sounds/offroute_drum.wav", on: offRoutePlayer, position: position, volume: 0.92)
    }
  }

  func updateProbeListenerYawDegrees(_ yawDegrees: Double) {
    environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(
      yaw: Float(-yawDegrees),
      pitch: 0,
      roll: 0
    )
  }

  func stopProbe() {
    stopOffRouteAlert()
  }

  func register(with messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    lookupAssetKey = { asset in
      registrar.lookupKey(forAsset: asset)
    }

    let methodChannel = FlutterMethodChannel(
      name: SpatialAudioChannelContract.methodChannel,
      binaryMessenger: messenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "spatial_bridge_unavailable", message: nil, details: nil))
        return
      }

      switch call.method {
      case SpatialAudioChannelContract.getCapabilitiesMethod:
        result([
          SpatialAudioChannelContract.supportsSpatialKey: canUseSpatialAudio(),
          SpatialAudioChannelContract.supportsStereoPanKey: true,
          SpatialAudioChannelContract.isMonoAudioEnabledKey: UIAccessibility.isMonoAudioEnabled,
          SpatialAudioChannelContract.hasHeadphonesConnectedKey: hasHeadphonesConnected(),
        ])
      case SpatialAudioChannelContract.playCueMethod:
        let args = call.arguments as? [String: Any]
        let cueType = args?[SpatialAudioChannelContract.cueTypeKey] as? String ?? ""
        self.playCue(type: cueType)
        result(nil)
      case SpatialAudioChannelContract.playStereoAssetMethod:
        let args = call.arguments as? [String: Any] ?? [:]
        let assetPath = args[SpatialAudioChannelContract.assetPathKey] as? String ?? ""
        let volume = (args[SpatialAudioChannelContract.volumeKey] as? NSNumber)?.floatValue ?? 0.25
        let rate = (args[SpatialAudioChannelContract.rateKey] as? NSNumber)?.floatValue ?? 1.0
        self.playStereoAsset(assetPath, volume: volume, rate: rate)
        result(nil)
      case SpatialAudioChannelContract.updateOffRouteAlertMethod:
        let args = call.arguments as? [String: Any] ?? [:]
        let side = args[SpatialAudioChannelContract.sideKey] as? String ?? "center"
        let severity = (args[SpatialAudioChannelContract.severityKey] as? NSNumber)?.doubleValue ?? 0
        let headingErrorDeg =
          (args[SpatialAudioChannelContract.headingErrorDegKey] as? NSNumber)?.doubleValue ?? 180
        let relativeAngleDeg =
          (args[SpatialAudioChannelContract.relativeAngleDegKey] as? NSNumber)?.doubleValue ?? 0
        let sourceDistanceMeters =
          (args[SpatialAudioChannelContract.sourceDistanceMetersKey] as? NSNumber)?.doubleValue ?? 2
        let distanceToWaypointMeters =
          (args[SpatialAudioChannelContract.distanceToWaypointMetersKey] as? NSNumber)?.doubleValue ?? 6
        self.updateOffRouteAlert(
          side: side,
          severity: severity,
          headingErrorDeg: headingErrorDeg,
          relativeAngleDeg: relativeAngleDeg,
          sourceDistanceMeters: sourceDistanceMeters,
          distanceToWaypointMeters: distanceToWaypointMeters
        )
        result(nil)
      case SpatialAudioChannelContract.primeOffRouteLoopMethod:
        try? self.ensureInitialized()
        self.primeSilentOffRouteLoop()
        result(nil)
      case SpatialAudioChannelContract.stopOffRouteAlertMethod:
        self.stopOffRouteAlert()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func ensureInitialized() throws {
    guard !isInitialized else { return }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playback,
      mode: .default,
      options: [.mixWithOthers]
    )
    try session.setPreferredSampleRate(48_000)
    try session.setActive(true)

    let outputFormat = engine.outputNode.inputFormat(forBus: 0)
    let inputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: outputFormat.sampleRate,
      channels: 1,
      interleaved: false
    )!
    spatialInputFormat = inputFormat

    engine.attach(environmentNode)
    engine.attach(eventPlayer)
    engine.attach(offRoutePlayer)

    engine.connect(eventPlayer, to: environmentNode, format: inputFormat)
    engine.connect(offRoutePlayer, to: environmentNode, format: inputFormat)
    engine.connect(environmentNode, to: engine.mainMixerNode, format: outputFormat)

    eventPlayer.renderingAlgorithm = .HRTFHQ
    offRoutePlayer.renderingAlgorithm = .HRTFHQ
    eventPlayer.reverbBlend = 10
    offRoutePlayer.reverbBlend = 42
    environmentNode.outputVolume = 1.0
    environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(
      yaw: 0,
      pitch: 0,
      roll: 0
    )

    engine.prepare()
    try engine.start()
    isInitialized = true
  }

  private func playCue(type: String) {
    try? ensureInitialized()

    switch type {
    case "waypointAdvanced":
      playEventAsset("assets/sounds/waypoint_pass.wav", position: AVAudio3DPoint(x: 0, y: 0, z: -1.2))
    case "waypointRegressed":
      playEventAsset("assets/sounds/waypoint_error.wav", position: AVAudio3DPoint(x: 0, y: 0, z: -1.0))
    case "arrived":
      playEventAsset("assets/sounds/waypoint_pass.wav", position: AVAudio3DPoint(x: 0, y: 0, z: -0.9))
    case "turnNow":
      playEventAsset("assets/sounds/offroute_chime.wav", position: AVAudio3DPoint(x: 0, y: 0, z: -1.0))
    default:
      break
    }
  }

  private func updateOffRouteAlert(
    side: String,
    severity: Double,
    headingErrorDeg: Double,
    relativeAngleDeg: Double,
    sourceDistanceMeters: Double,
    distanceToWaypointMeters: Double
  ) {
    try? ensureInitialized()
    offRouteSide = side
    offRouteSeverity = severity
    offRouteHeadingErrorDeg = headingErrorDeg
    self.relativeAngleDeg = relativeAngleDeg
    self.sourceDistanceMeters = sourceDistanceMeters
    self.distanceToWaypointMeters = distanceToWaypointMeters
    ensureOffRoutePulseRunning()
  }

  private func stopOffRouteAlert() {
    offRouteSeverity = 0
    offRouteHeadingErrorDeg = 180
    relativeAngleDeg = 0
    offRoutePulseTimer?.invalidate()
    offRoutePulseTimer = nil
    stereoPlayer?.stop()
    offRoutePlayer.volume = 0
    offRoutePlayer.stop()
  }

  private func playStereoAsset(_ asset: String, volume: Float, rate: Float) {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playback,
      mode: .default,
      options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
    )
    try? session.setActive(true)

    guard let url = resolvedAssetURL(for: asset) else { return }

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.volume = volume
      player.enableRate = true
      player.rate = max(0.5, min(2.0, rate))
      player.prepareToPlay()
      player.play()
      stereoPlayer = player
    } catch {
      return
    }
  }

  private func canUseSpatialAudio() -> Bool {
    !UIAccessibility.isMonoAudioEnabled && hasHeadphonesConnected()
  }

  private func hasHeadphonesConnected() -> Bool {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    return outputs.contains { output in
      switch output.portType {
      case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
        return true
      default:
        return false
      }
    }
  }

  private func ensureOffRoutePulseRunning() {
    if offRoutePulseTimer != nil {
      return
    }

    playOffRoutePulse()
  }

  private func primeSilentOffRouteLoop() {
    // Intentionally left as a no-op in the main app. The native HRTF probe
    // proved spatial playback works, but the looping-buffer warmup path used
    // here was crashing on scheduleBuffer(..., .loops) after localization.
    // Main-app guidance now relies on single-shot HRTF pulses only.
    isPrimedSilently = true
  }

  private func continuousBeaconAsset() -> String {
    if offRouteHeadingErrorDeg < 18 {
      return "assets/sounds/offroute_chime.wav"
    }

    return "assets/sounds/offroute_drum.wav"
  }

  private func directionalPosition(
    relativeAngleDeg: Double,
    distanceMeters: Double
  ) -> AVAudio3DPoint {
    let normalizedAngleDeg = ((relativeAngleDeg + 180).truncatingRemainder(dividingBy: 360)) - 180
    let theta = normalizedAngleDeg * .pi / 180.0
    let distance = max(0.8, min(6.0, distanceMeters))
    let x = Float(sin(theta) * distance)
    let z = Float(-cos(theta) * distance)

    return AVAudio3DPoint(x: x, y: 0.0, z: z)
  }

  private func playOffRoutePulse() {
    guard abs(offRouteHeadingErrorDeg) <= 180 else {
      offRoutePulseTimer?.invalidate()
      offRoutePulseTimer = nil
      offRoutePlayer.stop()
      return
    }

    let asset = continuousBeaconAsset()
    let effectiveSourceDistance = min(sourceDistanceMeters, distanceToWaypointMeters, 6.0)
    let position = directionalPosition(
      relativeAngleDeg: relativeAngleDeg,
      distanceMeters: effectiveSourceDistance
    )
    let volume = Float(lerp(0.22, 0.56, offRouteSeverity))

    playAsset(asset, on: offRoutePlayer, position: position, volume: volume)

    let nextInterval = guidancePulseInterval(headingErrorDeg: offRouteHeadingErrorDeg)
    offRoutePulseTimer?.invalidate()
    offRoutePulseTimer = Timer.scheduledTimer(withTimeInterval: nextInterval, repeats: false) {
      [weak self] _ in
      self?.playOffRoutePulse()
    }
  }

  private func guidancePulseInterval(headingErrorDeg: Double) -> TimeInterval {
    let minFrequencyHz = 0.5
    let maxHeadingFrequencyHz = 2.0
    let maxDistanceFrequencyHz = 3.4
    let normalizedAngle = max(0.0, min(1.0, abs(headingErrorDeg) / 180.0))
    let headingFrequencyHz =
      minFrequencyHz + ((maxHeadingFrequencyHz - minFrequencyHz) * normalizedAngle)
    let normalizedDistance =
      max(0.0, min(1.0, (6.0 - distanceToWaypointMeters) / (6.0 - 0.8)))
    let distanceFrequencyHz =
      minFrequencyHz + ((maxDistanceFrequencyHz - minFrequencyHz) * normalizedDistance)
    let frequencyHz = max(headingFrequencyHz, distanceFrequencyHz)
    return 1.0 / frequencyHz
  }

  private func playEventAsset(_ asset: String, position: AVAudio3DPoint) {
    playAsset(
      asset,
      on: eventPlayer,
      position: position,
      volume: 0.95
    )
  }

  private func playAsset(
    _ asset: String,
    on player: AVAudioPlayerNode,
    position: AVAudio3DPoint,
    volume: Float
  ) {
    guard
      let file = audioFile(for: asset),
      let targetFormat = spatialInputFormat,
      let buffer = convertedPCMBuffer(from: file, to: targetFormat)
    else { return }

    player.stop()
    player.position = position
    player.volume = volume
    player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    player.play()
  }

  private func convertedPCMBuffer(
    from file: AVAudioFile,
    to targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let sourceFormat = file.processingFormat
    let sourceFrameCount = AVAudioFrameCount(file.length)

    guard
      let sourceBuffer = AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: sourceFrameCount
      )
    else { return nil }

    do {
      try file.read(into: sourceBuffer)
    } catch {
      return nil
    }

    if sourceFormat.channelCount == targetFormat.channelCount &&
      sourceFormat.sampleRate == targetFormat.sampleRate &&
      sourceFormat.commonFormat == targetFormat.commonFormat &&
      sourceFormat.isInterleaved == targetFormat.isInterleaved {
      return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      return nil
    }

    let sampleRateRatio = targetFormat.sampleRate / sourceFormat.sampleRate
    let estimatedFrameCapacity = AVAudioFrameCount(
      ceil(Double(sourceBuffer.frameLength) * sampleRateRatio)
    ) + 32

    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: estimatedFrameCapacity
    ) else { return nil }

    var error: NSError?
    var consumedSource = false
    let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
      if consumedSource {
        outStatus.pointee = .endOfStream
        return nil
      }
      consumedSource = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }

    guard status != .error, error == nil else {
      return nil
    }

    return convertedBuffer
  }

  private func audioFile(for asset: String) -> AVAudioFile? {
    guard let url = resolvedAssetURL(for: asset) else { return nil }
    return try? AVAudioFile(forReading: url)
  }

  private func resolvedAssetURL(for asset: String) -> URL? {
    if let key = lookupAssetKey?(asset) {
      if let resourceURL = Bundle.main.resourceURL {
        let candidate = resourceURL.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
      if let bundleURL = Bundle.main.bundleURL as URL? {
        let candidate = bundleURL.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }

    if let frameworksURL = Bundle.main.privateFrameworksURL {
      let candidate = frameworksURL
        .appendingPathComponent("App.framework")
        .appendingPathComponent("flutter_assets")
        .appendingPathComponent(asset)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    if let resourceURL = Bundle.main.resourceURL {
      let enumerator = FileManager.default.enumerator(
        at: resourceURL,
        includingPropertiesForKeys: nil
      )
      let fileName = URL(fileURLWithPath: asset).lastPathComponent
      while let candidate = enumerator?.nextObject() as? URL {
        if candidate.lastPathComponent == fileName {
          return candidate
        }
      }
    }

    return nil
  }

  private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + ((b - a) * t)
  }
}
