#!/usr/bin/env ruby

require 'net/ssh'
require 'colorize'
require 'yaml'

$host = ARGV[0]
$os = nil
$config = nil

# This guy returns a hash, exit_code (Fixnum), stdout (Array), stderr (Array)
# By default will print output to the screen, you may turn off.
# Example: ssh_command("ls", p_stdout: false, p_stderr: false )
def ssh_command(cmd, p_stdout: true, p_stderr: true, ssh_timeout: 10, puppet_run: false)
  exit_code = 0
  stdout = Array.new
  stderr = Array.new
  eval_time = Hash.new
  Net::SSH.start($host, 'root', :paranoid => false, :timeout => ssh_timeout) do |ssh|
    channel = ssh.open_channel do |ch|
      ch.exec cmd do |ch, success|
        raise "could not execute command" unless success
        # "on_data" is called when the process writes something to stdout
        ch.on_data do |c, data|
          stdout.push(data)
          if puppet_run
            data.match(/Info: (.*): Evaluated in (.*) seconds/)
            eval_time[$1] = $2 unless ($1.nil? or $2.nil?)
            #if data =~ /Info: .*: (Starting to evaluate the resource|Evaluated in .* seconds)|Debug: .*/
            #  $stdout.print "\r"
            #else
            #  $stdout.print data if p_stdout
            #end
          end
          $stdout.print data if p_stdout
        end

        # "on_extended_data" is called when the process writes something to stderr
        ch.on_extended_data do |c, type, data|
          stderr.push(data)
          $stderr.print data if p_stderr
        end

        ch.on_request("exit-status") do |c, data|
          exit_code = data.read_long
        end

        ch.on_close { print "\n\nCommand Exited:\n\n#{cmd.colorize(:blue)}\n\nExit code: #{exit_code}\n\n" }
      end
    end
    channel.wait
  end
  return { :exit_code => exit_code, :stdout => stdout, :stderr => stderr, :eval_time => eval_time }
end

def which_os
  $os = ssh_command("uname -s")[:stdout].first.chomp.downcase
end

def os
  $os
end

def stop_agent
  print "#{nls}Stopping and disabling agent!#{nls}"
  ssh_command("printf \"service { \'puppet\':\n\tensure    => \'stopped\',\n\tenable    => \'false\',\n}\n\" > /tmp/puppet-service.pp")
  ssh_command("puppet apply /tmp/puppet-service.pp")
end

def rsync_build_cmd
  combined_excludes = $config['rsync']['excludes'][os] + $config['rsync']['excludes']['common']
  final_excludes = combined_excludes.map { |e| "--exclude \"#{e}\"" }.join(" ")
  flags = $config['rsync']['flags'].join(" ")
  { :excludes => final_excludes, :flags => flags }
end

def puppet_build_cmd
  flags = $config['puppet']['flags'].join(" ")
  { :flags => flags }
end

def rsync_revert
  rsync_cmd = "rsync #{rsync_build_cmd[:flags]} #{rsync_build_cmd[:excludes]} /var/recover/ /"
  #print "DEBUG RSYNC CMD: #{rsync_cmd}"
  print "#{nls}Reverting host to fresh state ...#{nls}"
  ssh_command(rsync_cmd)
end

def reboot_command
  case os
  when "linux"
    "reboot"
  when "aix"
    "shutdown -Fr"
  when "sunos"
    "init 6"
  end
end

def nls(num = 3)
  newlines = Array.new
  1.upto(num) do |n|
    newlines.push("\n")
  end
  newlines.join("")
end

def reboot_and_wait_for_host
  stop_agent
  print "#{nls}Rebooting host and waiting ...#{nls}"
  ret = ssh_command("nohup #{reboot_command} &")
  print "#{nls}Sleeping for 10 seconds ...#{nls}"
  sleep 10
  #puts ret[:exit_code]
  status = 1
  while status > 0
    is_host_rebooting?
    puts "#{nls}Verifying host rebooted ...#{nls}"
    ret = ssh_command("ls >/dev/null", ssh_timeout: 2)
    status = ret[:exit_code]
    print "#{nls}Sleeping for 5 seconds ...#{nls}"
    sleep 5
  end
  ret = ssh_command("ls", ssh_timeout: 2)
  puts "#{nls}Host is back up!#{nls}"
  ret[:exit_code]
end

def flush_output
  $stdout.sync = true
  $stderr.sync = true
end

def is_host_rebooting?
  rebooting = 1
  while rebooting > 0
    print "#{nls}Checking if host is still rebooting ... "
    ret = nil
    sleep 10
    begin
      ret = ssh_command("who -r", ssh_timeout: 2)
    rescue Exception => e
      print "Exception #{e} occured, continuing...\n"
      next
    end
    if ret[:exit_code] == 0 && ret[:stdout].first.split(/\s+/)[3].to_i == 6
      print "yes ... continuing to wait.\n"
      sleep 10
    else
      rebooting = 0
    end
  end
end

def puppet_run_cmd(run)
  "/opt/puppetlabs/bin/puppet agent #{puppet_build_cmd[:flags]}"
end

def print_errors(stderr)
  print nls
  print "Errors:\n"
  stderr.each do |err|
    puts err
  end
  print nls
end

def do_print_sort_eval_time(time, run)
  print "\n\n*** Begin Run #{run} Top #{top_stats_num} Resource Evaluation Profiling Statistics ***\n\n".colorize(:light_blue)
  time.sort_by {|_key, value| value.to_f}.last(top_stats_num).map { |l| print "\nResource: #{l[0].to_s.colorize(:green)}\nSeconds: #{l[1].to_s.colorize(:red)}\n" }
  print "\n\n*** End Run #{run} Resource Evaluation Profiling Statistics ***\n\n".colorize(:light_blue)
end

def do_puppet_runs
  print "#{nls}Running Puppet Agent (1/3), should return 2 (HAS CHANGES)...#{nls}"
  ret = ssh_command(puppet_run_cmd(1), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 1)
  if ret[:exit_code] != 2
    print_errors(ret[:stderr])
    exit ret[:exit_code]
  end

  reboot_and_wait_for_host

  print "#{nls}Running Puppet Agent (2/3), should return 2 (HAS CHANGES)...#{nls}"
  ret = ssh_command(puppet_run_cmd(2), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 2)
  if ret[:exit_code] != 2
    print_errors(ret[:stderr])
    exit ret[:exit_code]
  end

  print "#{nls}Running Puppet Agent (3/3), should return 0 (NO CHANGES OR ERRORS)...#{nls}"
  ret = ssh_command(puppet_run_cmd(3), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 3)
  if ret[:exit_code] != 0
    print_errors(ret[:stderr])
  end
  exit ret[:exit_code]
end

def top_stats_num
  5
end

def do_set_config
  $config = YAML.load_file("./test_integration.yaml")
end

def do_rsync_revert
  rsync_revert
  reboot_and_wait_for_host
  rsync_revert
  reboot_and_wait_for_host
end

# Begin main script
flush_output
do_set_config
which_os
do_rsync_revert
do_puppet_runs
