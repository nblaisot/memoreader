#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint sqlite_vec.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'memoreader_sqlite_vec'
  s.module_name = 'sqlite_vec'
  s.version          = '0.1.6'
  s.summary          = 'MemoReader pinned sqlite-vec extension.'
  s.description      = <<-DESC
MemoReader pinned sqlite-vec extension.
                       DESC
  s.homepage         = 'https://github.com/asg017/sqlite-vec'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'MemoReader contributors'

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) SQLITE_VEC_OMIT_FS=1' }
  s.swift_version = '5.0'
end
