Pod::Spec.new do |s|
  s.name             = 'TruflagSDK'
  s.version          = '0.1.0'
  s.summary          = 'Truflag Swift SDK for feature flags and telemetry.'
  s.description      = <<-DESC
Truflag Swift SDK provides flag evaluation, identity lifecycle, and telemetry
tracking for iOS apps.
  DESC
  s.homepage         = 'https://github.com/truflag/truflag-swift-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Truflag' => 'support@truflag.com' }
  s.source           = {
    :git => 'https://github.com/truflag/truflag-swift-sdk.git',
    :tag => s.version.to_s
  }

  s.platform         = :ios, '13.0'
  s.swift_version    = '6.0'
  s.requires_arc     = true

  s.source_files     = 'Sources/TruflagSDK/**/*.swift'
end
