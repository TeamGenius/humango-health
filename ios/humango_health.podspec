#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint humango_health.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'humango_health'
  s.version          = '0.0.13'
  s.summary          = 'Flutter plugin for iOS HealthKit & WorkoutKit — health metrics, workouts, sleep.'
  s.description      = <<-DESC
  Flutter plugin for integrating iOS HealthKit and WorkoutKit into other apps.
  Capture health metrics (HRV, resting HR, body fat, weight, height), read and
  monitor workouts, push scheduled workouts to Apple Watch, and read/monitor
  sleep data. Workouts, sleep payloads, and metric batches are delivered to the host app via `HumangoHealthDataDelegate` (no plugin HTTP). iOS 18.0+.
                       DESC
  s.homepage         = 'https://github.com/humango/humango-health'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Humango' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '18.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'humango_health_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
