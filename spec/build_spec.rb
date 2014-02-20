require_relative 'spec_helper'
require_relative '../lib/build'

require 'pry'

describe 'Build' do
  describe :run do

    describe 'basic' do
      let(:build) { GitlabCi::Build.new(build_data({})) }

      before :each do
        build.run
      end

      it { build.trace.should include 'bundle' }
      it { build.trace.should include 'HEAD is now at 2e008a7' }
      it { build.state.should == :success }
    end

    describe 'use_docker: true' do
      let(:build) { GitlabCi::Build.new(docker_build) }

      before :each do
        build.run
      end

      it { build.trace.should include 'hello world' }
      it { build.trace.should include 'HEAD is now at 11e6cc' }
      it { build.state.should == :success }
    end
  end

  def docker_build
    data = {
      commands: ['echo hello world'],
      project_id: 1,
      id: 9313,
      ref: '11e6cc68adf7f6bb93bf3e8772c2ec3af238205b',
      repo_url: 'https://github.com/MatthewMueller/coderunner'
    }
    data[:opts] = {use_docker: true}
    return data
  end

  def build_data(opts)
    data = {
      commands: ['bundle'],
      project_id: 0,
      id: 9312,
      ref: '2e008a711430a16092cd6a20c225807cb3f51db7',
      repo_url: 'https://github.com/randx/six.git'
    }
    data[:opts] = {}
    return data
  end
end
