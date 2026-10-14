import Foundation

// `LiveKitWebRTC` is built with `RTC_OBJC_TYPE_PREFIX = LK`; these aliases restore the
// canonical `RTC…` names, and are the only file to change if the binary is repointed.
@_exported import LiveKitWebRTC

// MARK: - Peer connection

typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
typealias RTCPeerConnection = LKRTCPeerConnection
typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
typealias RTCConfiguration = LKRTCConfiguration
typealias RTCMediaConstraints = LKRTCMediaConstraints
typealias RTCStatisticsReport = LKRTCStatisticsReport

// Enums carry the prefix on the type but not on the imported case names, so
// `RTCSignalingState.stable` keeps working through the alias.
typealias RTCSignalingState = LKRTCSignalingState
typealias RTCIceConnectionState = LKRTCIceConnectionState
typealias RTCIceGatheringState = LKRTCIceGatheringState

// MARK: - SDP and ICE

typealias RTCSessionDescription = LKRTCSessionDescription
typealias RTCIceCandidate = LKRTCIceCandidate
typealias RTCIceServer = LKRTCIceServer

// MARK: - Media

typealias RTCAudioSource = LKRTCAudioSource
typealias RTCAudioTrack = LKRTCAudioTrack
typealias RTCMediaStream = LKRTCMediaStream
typealias RTCMediaStreamTrack = LKRTCMediaStreamTrack
typealias RTCRtpReceiver = LKRTCRtpReceiver
typealias RTCRtpTransceiver = LKRTCRtpTransceiver

// MARK: - Data channel

typealias RTCDataChannel = LKRTCDataChannel
typealias RTCDataChannelDelegate = LKRTCDataChannelDelegate
typealias RTCDataChannelConfiguration = LKRTCDataChannelConfiguration
typealias RTCDataBuffer = LKRTCDataBuffer
typealias RTCDataChannelState = LKRTCDataChannelState

// MARK: - Audio session

typealias RTCAudioSession = LKRTCAudioSession
typealias RTCAudioSessionConfiguration = LKRTCAudioSessionConfiguration
typealias RTCAudioSessionDelegate = LKRTCAudioSessionDelegate

// MARK: - Recording taps
//
// Renderers tap the remote track; the mic uses the capture processing delegate because in
// M144 `LocalAudioSource::AddSink` is empty, so a renderer on the local track never fires.
typealias RTCAudioRenderer = LKRTCAudioRenderer
typealias RTCAudioCustomProcessingDelegate = LKRTCAudioCustomProcessingDelegate
typealias RTCAudioBuffer = LKRTCAudioBuffer
typealias RTCDefaultAudioProcessingModule = LKRTCDefaultAudioProcessingModule
typealias RTCAudioProcessingModule = LKRTCAudioProcessingModule
typealias RTCAudioProcessingConfig = LKRTCAudioProcessingConfig
typealias RTCAudioDeviceModuleType = LKRTCAudioDeviceModuleType

// Per-component processing control, used to read back `audioProcessingState`.
typealias RTCAudioProcessingOptions = LKRTCAudioProcessingOptions
typealias RTCAudioProcessingComponentOptions = LKRTCAudioProcessingComponentOptions
typealias RTCAudioProcessingMode = LKRTCAudioProcessingMode
typealias RTCAudioProcessingState = LKRTCAudioProcessingState

// MARK: - Free functions

@inline(__always)
func RTCInitializeSSL() -> Bool { LKRTCInitializeSSL() }
