require_relative 'encode'
require_relative 'config'

require 'childprocess'
require 'tempfile'
require 'fileutils'
require 'bundler'

require 'docker'
require 'shellwords'
require 'pry'
# The changes Docker always makes to the filesystem
DOCKER_FS_CHANGES = [{"Kind"=>0, "Path"=>"/dev"}, {"Kind"=>1, "Path"=>"/dev/kmsg"}]

module GitlabCi
  class Build
    TIMEOUT = 7200

    attr_accessor :id, :commands, :ref, :tmp_file_path, :output, :state, :before_sha

    def initialize(data)
      @commands = data[:commands].to_a
      @ref = data[:ref]
      @ref_name = data[:ref_name]
      @opts = data[:opts] or {}
      @id = data[:id]
      @project_id = data[:project_id]
      @repo_url = data[:repo_url]
      @state = :waiting
      @before_sha = data[:before_sha]
      @timeout = data[:timeout] || TIMEOUT
      @allow_git_fetch = data[:allow_git_fetch]
    end

    def run
      @state = :running

      setup_commands = []
      setup_commands.unshift(checkout_cmd)


      if repo_exists? && @allow_git_fetch
        setup_commands.unshift(fetch_cmd)
      else
        FileUtils.rm_rf(project_dir)
        FileUtils.mkdir_p(project_dir)
        setup_commands.unshift(clone_cmd)
      end

      if @opts[:use_docker]
          begin
            setup_docker setup_commands
          rescue
            status = false
          else
            status = docker_run @commands
          end
          cleanup_docker
      else
        @commands = setup_commands + @commands
        @commands.each do |line|
          status = Bundler.with_clean_env { command line }
        end
      end

      @state = :failed and return unless status

      @state = :success
    end

    def completed?
      success? || failed?
    end

    def success?
      state == :success
    end

    def failed?
      state == :failed
    end

    def running?
      state == :running
    end

    def trace
      output + tmp_file_output
    rescue
      ''
    end

    def tmp_file_output
      tmp_file_output = GitlabCi::Encode.encode!(File.binread(tmp_file_path)) if tmp_file_path && File.readable?(tmp_file_path)
      tmp_file_output ||= ''
    end

    private

    def setup_docker(setup_commands)
      raise RuntimeError, "docker daemon not found" if Docker.version.nil?
      setup_commands.each do |cmd|
        status = Bundler.with_clean_env { command cmd }
        raise RuntimeError unless status
      end

      raise NameError, "No Dockerfile found" unless FileTest.file? "#{project_dir}/Dockerfile"

      build_image = Docker::Image.build_from_dir(project_dir)
      @docker_images = [build_image]
      @docker_containers = []
    end

    # Run each command within the docker container, but persist state.
    # Fail if the command fails.
    def docker_run(commands)

      have_error = false
      @run_start_time = Time.now
      host_image = @docker_images[0]

      commands.each do |cmd|
        container = Docker::Container.create 'Image' => host_image.id,
          'Cmd' => Shellwords.shellwords(cmd)
        @docker_containers << container

        container.start
        begin
          # Wait the rest of the time we were alotted to run this
          container.wait @timeout - (Time.now - @run_start_time)

          if container.json['State']['ExitCode'] != 0
            have_error = true
            break
          end

        rescue Docker::Error::TimeoutError
          @output << "TIMEOUT"
          container.kill # tries increasingly harsher methods to kill the process.
          break
        ensure
          stdout, stderr = container.attach logs: true, stdout: true, stderr: true, stream: false
          stdout.each do |pipe|
            @output << GitlabCi::Encode.encode!(pipe)
          end
          stderr.each do |pipe|
            @output << GitlabCi::Encode.encode!(pipe)
          end
        end

        # Look and see if the filesystem changed at all.
        # If it did, save the container and run the next command from it.
        if (container.changes - DOCKER_FS_CHANGES).length > 0
          host_image = container.commit
          @docker_images << host_image
        end
      end
    end

    def cleanup_docker
      @docker_containers.each do |container|
        container.delete
      end
      @docker_images.each do |image|
        begin
          image.remove
        rescue
          # Exceptions here are okay. container.delete removes images too
        end
      end
    end

    def command(cmd)
      cmd = cmd.strip

      @output ||= ""
      @output << "\n"
      @output << cmd
      @output << "\n"

      @process = ChildProcess.build('bash', '--login', '-c', cmd)
      @tmp_file = Tempfile.new("child-output", binmode: true)
      @process.io.stdout = @tmp_file
      @process.io.stderr = @tmp_file
      @process.cwd = project_dir

      # ENV
      # Bundler.with_clean_env now handles PATH, GEM_HOME, RUBYOPT & BUNDLE_*.

      @process.environment['CI_SERVER'] = 'yes'
      @process.environment['CI_SERVER_NAME'] = 'GitLab CI'
      @process.environment['CI_SERVER_VERSION'] = nil# GitlabCi::Version
      @process.environment['CI_SERVER_REVISION'] = nil# GitlabCi::Revision

      @process.environment['CI_BUILD_REF'] = @ref
      @process.environment['CI_BUILD_BEFORE_SHA'] = @before_sha
      @process.environment['CI_BUILD_REF_NAME'] = @ref_name
      @process.environment['CI_BUILD_ID'] = @id

      @process.start

      @tmp_file_path = @tmp_file.path

      begin
        @process.poll_for_exit(@timeout)
      rescue ChildProcess::TimeoutError
        @output << "TIMEOUT"
        @process.stop # tries increasingly harsher methods to kill the process.
        return false
      end

      @process.exit_code == 0

    rescue => e
      # return false if any exception occurs
      @output << e.message
      false

    ensure
      @tmp_file.rewind
      @output << GitlabCi::Encode.encode!(@tmp_file.read)
      @tmp_file.close
      @tmp_file.unlink
    end

    def checkout_cmd
      cmd = []
      cmd << "cd #{project_dir}"
      cmd << "git reset --hard"
      cmd << "git checkout #{@ref}"
      cmd.join(" && ")
    end

    def clone_cmd
      cmd = []
      cmd << "cd #{config.builds_dir}"
      cmd << "git clone #{@repo_url} project-#{@project_id}"
      cmd << "cd project-#{@project_id}"
      cmd << "git checkout #{@ref}"
      cmd.join(" && ")
    end

    def fetch_cmd
      cmd = []
      cmd << "cd #{project_dir}"
      cmd << "git reset --hard"
      cmd << "git clean -fdx"
      cmd << "git remote set-url origin #{@repo_url}"
      cmd << "git fetch origin"
      cmd.join(" && ")
    end

    def repo_exists?
      File.exists?(File.join(project_dir, '.git'))
    end

    def config
      @config ||= Config.new
    end

    def project_dir
      File.join(config.builds_dir, "project-#{@project_id}")
    end
  end
end
