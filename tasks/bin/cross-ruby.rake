#--
# Cross-compile ruby, using Rake
#
# This source code is released under the MIT License.
# See LICENSE file for details
#++

#
# This code is inspired and based on notes from the following sites:
#
# http://tenderlovemaking.com/2008/11/21/cross-compiling-ruby-gems-for-win32/
# http://github.com/jbarnette/johnson/tree/master/cross-compile.txt
# http://eigenclass.org/hiki/cross+compiling+rcovrt
#
# This recipe only cleanup the dependency chain and automate it.
# Also opens the door to usage different ruby versions
# for cross-compilation.
#

abort <<-EOT if RUBY_PLATFORM =~ /mingw|mswin/
This tool is meant to be executed under Linux or OSX, not Windows.
It is used for cross-compilation only.
EOT

require 'rake'
require 'rake/clean'

require 'rbconfig'
require 'safe_yaml/load'

ruby_src = ENV['SRC']
ruby_svn = ENV['SVN']

make_command = ENV.fetch('MAKE') {
  require 'nuggets/file/which'
  File.which_command(%w[gmake make])
}

mingw_host = ENV.fetch('HOST') {
  require 'rake/extensioncompiler'
  Rake::ExtensionCompiler.mingw_host
}

version_name = 'ruby-%s' % ENV.fetch('VERSION') {
  '%s-p%s' % [RUBY_VERSION, RUBY_PATCHLEVEL]
}

# Grab the major "1.8" or "1.9" part of the version number
version_major = version_name[/.*-(\d\.\d)\.\d/, 1]

download_url = "http://cache.ruby-lang.org/pub/ruby/#{version_major}"
svn_repo_url = 'http://svn.ruby-lang.org/repos/ruby'

base_directory       = File.expand_path('~/.rake-compiler')
config_file          = File.join(base_directory, 'config.yml')

sources_directory    = File.join(base_directory, 'sources')
builds_directory     = File.join(base_directory, 'builds')
targets_directory    = File.join(base_directory, 'ruby')

source_directory     = File.join(sources_directory, version_name)
build_directory      = File.join(builds_directory,  mingw_host, version_name)
target_directory     = File.join(targets_directory, mingw_host, version_name)

tarball_file         = !ruby_src ? source_directory + '.tar.bz2' :
                       File.join(sources_directory, File.basename(ruby_src))

makefile_file        = File.join(build_directory, 'Makefile')
makefile_in_file     = File.join(source_directory, 'Makefile.in')
makefile_in_bak_file = makefile_in_file + '.bak'

build_ruby_exe_file  = File.join(build_directory, 'ruby.exe')
target_ruby_exe_file = File.join(target_directory, 'bin', 'ruby.exe')

# Unset any possible variable that might affect compilation
%w[CC CXX CPPFLAGS LDFLAGS RUBYOPT].each { |k| ENV.delete(k) }

# Define a location where sources will be stored
directory source_directory
directory build_directory

# Clean intermediate files and folders
CLEAN.include(source_directory)
CLEAN.include(build_directory)

# Remove the final products and sources
CLOBBER.include(sources_directory)
CLOBBER.include(builds_directory)
CLOBBER.include(target_directory)
CLOBBER.include(config_file)

# Ruby source file should be stored here
file tarball_file => sources_directory do |t|
  url = ruby_src || File.join(download_url, File.basename(t.name))
  chdir(sources_directory) { sh "wget #{url} || curl -O #{url}" }
end

# Extract the sources
if ruby_svn
  file source_directory => sources_directory do |t|
    sh "svn export -q #{File.join(svn_repo_url, ruby_svn)} #{t.name}"
    chdir(source_directory) { sh 'autoreconf' }
  end
else
  file source_directory => tarball_file do |t|
    chdir(sources_directory) { sh "tar xf #{tarball_file}" }
  end
end

# Backup makefile.in
file makefile_in_bak_file => source_directory do |t|
  cp makefile_in_file, t.name
end

# Correct the makefile
file makefile_in_file => makefile_in_bak_file do |t|
  out = ''

  File.foreach(t.name) { |line|
    line.sub!(/\A(\s*ALT_SEPARATOR =).*/, "\\1 \"\\\\\\\\\"; \\\n")
    out << line
  }

  when_writing('Patching Makefile.in') { File.write(t.name, out) }
end

# Generate the makefile in a clean build location
file makefile_file => [build_directory, makefile_in_file] do |t|
  options = %W[
    --host=#{mingw_host}
    --target=#{mingw_host.gsub('msvc', '')}
    --build=#{RbConfig::CONFIG['host']}
    --prefix=#{target_directory}
    --enable-shared
    --disable-install-doc
    --without-tk
    --without-tcl
  ]

  # Force Winsock2 for Ruby 1.8, 1.9 defaults to it
  options << '--with-winsock2' if version_major == '1.8'

  chdir(build_directory) {
    sh File.join(source_directory, 'configure'), *options
  }
end

# Make
file build_ruby_exe_file => makefile_file do |t|
  chdir(build_directory) { sh make_command }
end

# Make install
file target_ruby_exe_file => build_ruby_exe_file do |t|
  chdir(build_directory) { sh "#{make_command} install" }
end

task :install => target_ruby_exe_file

task :mingw32 do
  abort <<-EOT unless mingw_host
You need to install mingw32 cross compile functionality to be able to continue.
Please refer to your distribution/package manager documentation about installation.
  EOT
end

desc 'Update rake-compiler list of installed Ruby versions'
task 'update-config' do
  config = if File.exist?(config_file)
    puts "Updating #{config_file}"
    SafeYAML.load_file(config_file)
  else
    puts "Generating #{config_file}"
    {}
  end

  Dir["#{targets_directory}/*/*/**/rbconfig.rb"].sort.each { |rbconfig|
    if rbconfig =~ %r{.*-(\d.\d.\d).*/([-\w]+)/rbconfig}
      version, platform = $1, $2
    else
      warn "Invalid pattern: #{rbconfig}"
      next
    end

    platforms, key = [platform], "rbconfig-%s-#{version}"

    # Fake alternate (binary compatible) i386-mswin32-60 platform
    platforms << 'i386-mswin32-60' if platform == 'i386-mingw32'

    platforms.each { |pf|
      config[key % pf] = rbconfig

      # Also store RubyGems-compatible version
      config[key % Gem::Platform.new(pf)] = rbconfig
    }

    puts "Found Ruby version #{version} for platform #{platform} (#{rbconfig})"
  }

  when_writing("Saving changes into #{config_file}") {
    File.open(config_file, 'w') { |f| YAML.dump(config, f) }
  }
end

task :default do
  # Force the display of the available tasks when no option is given
  Rake.application.options.show_task_pattern = //
  Rake.application.options.show_tasks = :tasks
  Rake.application.display_tasks_and_comments
end

desc "Build #{version_name} suitable for cross-platform development."
task 'cross-ruby' => [:mingw32, :install, 'update-config']
