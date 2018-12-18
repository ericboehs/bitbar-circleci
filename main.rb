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

def time_ago(time)
  timestamp = time.to_i
  delta = Time.now.to_i - timestamp
  case delta
  when 0..30         then "just now"
  when 31..119       then "about a minute ago"
  when 120..3599     then "#{delta / 60} minutes ago"
  when 3600..86399   then "#{(delta / 3600).round} hours ago"
  when 86400..259199 then "#{(delta / 86400).round} days ago"
  else Time.at(timestamp).strftime('%d %B %Y %H:%M')
  end
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

def avatar username, size=16
  @avatars ||= {}
  @avatars[username+size.to_s] ||= `curl -sL "https://github.com/#{username}.png?size=#{size}" | base64`
end

master_builds = CircleCi::Project.new(ENV['CIRCLE_STATUS_USER'], ENV['CIRCLE_STATUS_REPO']).recent_builds_branch('master', limit: 15).body
latest_master_build = master_builds.select {|build| !%w[running scheduled queued canceled].include?(build['status']) }.first
master_status = latest_master_build['outcome']

recent_builds = CircleCi::Project.new(ENV['CIRCLE_STATUS_USER'], ENV['CIRCLE_STATUS_REPO']).recent_builds(limit: 10).body
running_or_waiting_builds = recent_builds.select {|build| %w[scheduled queued running not_running].include? build['status'] }
puts "CI: #{running_or_waiting_builds.count}|color=#{status_color master_status}"
puts '---'
puts "#{ENV['CIRCLE_STATUS_USER']}/#{ENV['CIRCLE_STATUS_REPO']}|href=https://circleci.com/gh/#{ENV['CIRCLE_STATUS_USER']}/#{ENV['CIRCLE_STATUS_REPO']}"
puts '---'

recent_builds.each do |build|
  puts "#{build['build_num']} (#{build['branch'][0..10]}): #{build['subject']}|href=#{build['build_url']} color=#{status_color build['status']} length=40 image=#{avatar build['user']['login']}"
  puts "-- #{build['build_num']}: #{build['subject']}|href=#{build['build_url']} color=#{status_color build['status']}"
  puts "-- Copy Build URL|bash=#{$0} param1=copy param2=#{build['build_url']} terminal=false"
  puts "-----"
  puts "-- Rebuild|bash=#{$0} param1=retry param2=#{build['username']} param3=#{build['reponame']} param4=#{build['build_num']} terminal=false"
  if %w[running scheduled queued].include?(build['status'])
    puts "-- Cancel|bash=#{$0} param1=cancel param2=#{build['username']} param3=#{build['reponame']} param4=#{build['build_num']} terminal=false"
  end
  puts "-----"
  puts "--#{build['user']['login']}|href=https://github.com/#{build['user']['login']} image=#{avatar build['user']['login'], 64}"
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

puts '---'
puts 'Refresh|refresh=true'
