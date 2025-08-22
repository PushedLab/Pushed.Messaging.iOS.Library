#
# Be sure to run `pod lib lint PushedMessagingiOSLibrary.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'PushedMessagingiOSLibrary'
  s.version          = '1.0.8'
  s.summary          = 'Pushed Messaging iOS Library.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/PushedLab/Pushed.Messaging.iOS.Library'
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Nikanson' => 'a.nikandrov@multifactor.ru' }
  s.source           = { :git => 'https://github.com/PushedLab/Pushed.Messaging.iOS.Library.git', :tag => s.version.to_s }
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'
  s.swift_version = '5.0'
  s.ios.deployment_target = '12.0'
  # Исходники пакета находятся в стандартной для SPM структуре
  s.source_files = 'Sources/PushedMessagingiOSLibrary/**/*.{swift}'
  
  # s.resource_bundles = {
  #   'PushedMessagingiOSLibrary' => ['PushedMessagingiOSLibrary/Assets/*.png']
  # }

  # s.public_header_files = 'Pod/Classes/**/*.h'
  # s.frameworks = 'UIKit', 'MapKit'
  # s.dependency 'AFNetworking', '~> 2.3'
  # Зависимость от Starscream для WebSocket (iOS 13+)
  s.dependency 'Starscream', '~> 4.0'
  # Зависимость от DeviceKit (используется внутри SDK)
  s.dependency 'DeviceKit', '~> 5.0'
end
