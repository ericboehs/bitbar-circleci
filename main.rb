#! /usr/local/bin/ruby
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'circleci'
  gem 'dotenv'
  gem 'pry'
end

require 'dotenv'; Dotenv.load "#{File.dirname($0)}/.env"
require 'circleci'
require 'date'

CircleCi.configure do |config|
  config.token = ENV['CIRCLE_TOKEN']
end

if ARGV[0] == 'copy'
  `/bin/zsh -c 'echo -n #{ARGV[1]} | pbcopy'`
  exit
end

if ARGV[0] == 'retry'
  build = CircleCi::Build.new ARGV[1], ARGV[2], nil, ARGV[3]
  build.retry
  exit
end

if ARGV[0] == 'cancel'
  build = CircleCi::Build.new ARGV[1], ARGV[2], nil, ARGV[3]
  build.cancel
  exit
end

def symbolize_keys hash
  hash.map { |(k,v)| [k.to_sym, v] }.to_h
end

def status_color status
  case status
  when 'fixed' then 'green'
  when 'success' then 'green'
  when 'failed' then 'red'
  when 'running' then '#00CCCC' # cyan
  when 'canceled' then '#AAAAAA' # dark gray
  when 'not_run' then '#AAAAAA' # dark gray
  when 'scheduled' then '#9d41f4' # purple
  when 'not_running' then '#9d41f4' # purple
  when 'queued' then '#9d41f4' # purple
  else 'black'
  end
end

def parse_time string, to_str=true
  return unless string
  time = DateTime.parse(string).to_time.getlocal
  to_str ? time.strftime("%I:%M %p") : time
end

def duration start_string, compare_to_now=true
  return unless start_string

  if compare_to_now
    duration_in_seconds = Time.now.to_i - timestamp = DateTime.parse(start_string).to_time.getlocal.to_i
  else
    duration_in_seconds = start_string.to_i
  end

  m = (duration_in_seconds / 60).to_i
  duration_in_seconds -= m * 60

  s = duration_in_seconds
  str = "%02i:%02i" % [m, s]
end

def avatar url, size=16
  @avatars ||= {}
  @avatars[url+size.to_s] ||= `curl -s "#{url}&size=#{size}" | base64`
end

class CircleBar
  attr_reader :token, :user, :repo

  def initialize token:, user:, repo:
    @token = token; @user = user; @repo = repo
  end

  def run
    puts menu_icon_text
    puts '---'
    puts project_link
    puts '---'

    refactor_me

    puts '---'
    puts 'Refresh|refresh=true'
  end

  def project
    @project ||= CircleCi::Project.new user, repo
  end

  def master_status
    master_builds = project.recent_builds_branch('master').body
    latest_build = master_builds.find { |build| %w[success failed].include? build['status'] }
    latest_build['outcome']
  end

  def recent_builds
    project.recent_builds(limit: 10).body
  end

  def in_progress_builds_count
    recent_builds.select { |build| %w[scheduled queued running not_running].include? build['status'] }.count
  end

  def menu_icon_text
    "CI: #{in_progress_builds_count}|color=#{status_color master_status}"
  end

  def project_link
    "#{user}/#{repo}|href=https://circleci.com/gh/#{user}/#{repo}"
  end

  def build_menu_item build_num:, branch:, subject:, build_url:, status:, user:, **_build
    "#{build_num} (#{branch[0..10]}): #{subject}|" \
      "href=#{build_url} " \
      "color=#{status_color status} " \
      "length=40 " \
      "image=#{avatar user['avatar_url']}"
  end

  def refactor_me
    recent_builds.each do |build|
      puts build_menu_item symbolize_keys build
      puts "-- #{build['build_num']}: #{build['subject']}|href=#{build['build_url']} color=#{status_color build['status']}"
      puts "-- Copy Build URL|bash=#{$0} param1=copy param2=#{build['build_url']} terminal=false"
      puts "-----"
      puts "-- Rebuild|bash=#{$0} param1=retry param2=#{build['username']} param3=#{build['reponame']} param4=#{build['build_num']} terminal=false"
      if %w[running scheduled queued].include?(build['status'])
        puts "-- Cancel|bash=#{$0} param1=cancel param2=#{build['username']} param3=#{build['reponame']} param4=#{build['build_num']} terminal=false"
      end
      puts "-----"
      puts "--#{build['user']['login']}|href=https://github.com/#{build['user']['login']} image=#{avatar build['user']['avatar_url'], 64}"
      puts "--#{build['branch']}|href=https://github.com/#{build['username']}/#{build['reponame']}/tree/#{build['branch']}"
      puts "--Compare #{build['vcs_revision'][0..8]}|href=#{build['compare']}"
      puts "--Queued: #{parse_time build['queued_at']}" if build['queued_at']
      start_time = parse_time build['start_time'], false if build['start_time']
      stop_time = parse_time build['stop_time'], false if build['stop_time']
      puts "--Started: #{parse_time build['start_time']}#{" (#{duration build['start_time']} ago)" unless build['stop_time']}" if build['start_time']
      puts "--Stop: #{parse_time build['stop_time']}" if build['stop_time']
      puts "--Duration: #{duration stop_time - start_time, false}" if build['start_time'] && build['stop_time']
      puts "--Estimated: #{duration build['previous_successful_build']['build_time_millis'] / 1000, false}"
      puts "--Build Time: #{build['build_time_millis']}" if build['build_time_millis']
      puts "--Why: #{build['why']}"

      if build['ssh_users'].any?
        puts "--SSH Users: #{build['ssh_users'].map{|user| user['login'] }.join ', '}"
      end
      if build['outcome']
        puts "--Outcome: #{build['outcome']}|color=#{status_color build['outcome']}"
      else
        puts "--Status: #{build['status']}|color=#{status_color build['status']}"
      end

      if build['outcome'] == 'failed' || build['status'] == 'running'
        build_details = CircleCi::Build.new build['username'], build['reponame'], nil, build['build_num']
        build = build_details.get.body

        if build['outcome'] == 'failed'
          tests = build_details.tests.body
          failed_tests = tests['tests'].select{|test| test['result'] != 'success' && test['result'] != 'skipped' }


          puts "-----"
          puts "-- Failures: "
          failed_tests.each do |failed_test|
            puts "-- #{failed_test['file']}"
            puts "---- #{failed_test['name']}"
            failed_test['message'].split("\n").each do |message|
              puts "---- #{message}"
            end
          end
        end

        puts "-----"
        puts "-- Steps: "
        actions = build['steps'].flat_map {|step| step['actions'] }.group_by {|action| action['index'] } if build['steps']
        failing_nodes = actions.map {|node, actions| [node, actions.map { |action| action['status'] }.all? {|s| s == "success" }] }.delete_if {|acts| acts[1] == true }.map(&:first)
        failing_nodes.map do |node|
          failing_actions = actions[node].map {|action|
            unless action['name'] =~ /Container circleci/
              if action['status'] != 'success'
                start_time = parse_time action['start_time'], false if action['start_time']
                end_time = parse_time action['end_time'], false if action['end_time']
                action_duration = duration end_time - start_time, false if action['start_time'] && action['end_time']
                action_duration ||= "#{duration action['start_time']} ago"
                puts "-- #{node}: #{action['name']} (#{action_duration})|href=https://circleci.com/gh/#{build['username']}/#{build['reponame']}/#{build['build_num']}#tests/containers/#{node} color=#{status_color action['status']}"
                begin
                  if action['output_url']
                    JSON.parse(Net::HTTP.get URI action['output_url']).first['message'].split("\r\n").grep(/expected/).each do |error|
                      puts "---- #{error}"
                    end
                  end
                rescue e
                  puts "---- #{e.message}"
                  require 'pry'; binding.pry
                end
              end
            end
          }
        end
      end
    end
  end
end

token = ENV.fetch 'CIRCLE_TOKEN'
user = ENV.fetch 'CIRCLE_STATUS_USER'
repo = ENV.fetch 'CIRCLE_STATUS_REPO'

circle_bar = CircleBar.new token: token, user: user, repo: repo
circle_bar.run
