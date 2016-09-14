#!/usr/bin/env ruby

require 'net/ssh'
require 'colorize'

$host = ARGV[0]
$os = nil

# This guy returns a hash, exit_code (Fixnum), stdout (Array), stderr (Array)
# By default will print output to the screen, you may turn off.
# Example: ssh_command("ls", p_stdout: false, p_stderr: false )
def ssh_command(cmd, p_stdout: true, p_stderr: true, ssh_timeout: 10, puppet_run: false)
  flush_output
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
            evaltime[$1] = $2 unless ($1.nil? or $2.nil?)
          end

          $stdout.print data if p_stdout
          $stdout.flush
        end

        # "on_extended_data" is called when the process writes something to stderr
        ch.on_extended_data do |c, type, data|
          stderr.push(data)
          $stderr.print data if p_stderr
          $stderr.flush
        end

        ch.on_request("exit-status") do |c, data|
          exit_code = data.read_long
        end

        ch.on_close { print "\n\nCommand Exited:\n\n#{cmd.colorize(:blue)}\n\nExit code: #{exit_code}\n\n" }
      end
    end
    channel.wait
  end
  flush_output
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

def rsync_revert
  rsync_cmd = String.new

  case os
  when "linux"
    rsync_cmd = "rsync -av --progress --delete --exclude /var/recover --exclude /dev --exclude /proc --exclude /sys --exclude /selinux --exclude '/var/run/*.pid' --exclude '/var/run/*/*.pid' --exclude /nfs --exclude /depot --exclude /var/lib/nfs /var/recover/ /"
  when "aix"
    rsync_cmd = "rsync -av --progress --delete --exclude /var/recover --exclude /dev --exclude /proc --exclude /nfs /var/recover/ /"
  when "sunos"
   rsync_cmd = "rsync -av --progress --delete --exclude /var/recover --exclude /dev --exclude /devices --exclude /proc --exclude /system --exclude /nfs --exclude /etc/svc/volatile --exclude /etc/mnttab --exclude /etc/dfs/sharetab --exclude /var/run --exclude '/etc/sysevent/*door*' --exclude '/etc/sysevent/*channel*' --exclude /rpool /var/recover/ /"
  end

  print "#{nls}Reverting host to fresh state ...#{nls}"
  ssh_command(rsync_cmd)
end

def reboot_command(host = $host)
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
  flush_output
  print "#{nls}Rebooting host and waiting ...#{nls}"
  ret = ssh_command("nohup #{reboot_command} &")
  print "#{nls}Sleeping for 10 seconds ...#{nls}"
  sleep 10
  #puts ret[:exit_code]
  status = 1
  while status > 0
    flush_output
    is_host_rebooting?
    puts "#{nls}Verifying host rebooted ...#{nls}"
    ret = ssh_command("ls >/dev/null", ssh_timeout: 2)
    status = ret[:exit_code]
    print "#{nls}Sleeping for 10 seconds ...#{nls}"
    sleep 10
    flush_output
  end
  ret = ssh_command("ls", ssh_timeout: 2)
  puts "#{nls}Host is back up!#{nls}"
  ret[:exit_code]
end

def flush_output
  $stdout.flush
  $stderr.flush
end

def is_host_rebooting?
  flush_output
  rebooting = 1
  while rebooting > 0
    print "\n\n\nChecking if host is still rebooting ... "
    ret = nil
    sleep 10
    begin
      ret = ssh_command("who -r", ssh_timeout: 2)
      flush_output
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
    flush_output
  end
end

def puppet_run_cmd(run)
  "/opt/puppet/bin/puppet agent -td --evaltrace --logdest=/tmp/puppet_profile_#{run}.log"
end

def print_errors(stderr)
  print "\n\n"
  print "Errors:\n"
  stderr.each do |err|
    puts err
  end
  print "\n\n"
end

def do_print_sort_eval_time(time, run)
  print "\n\n*** Begin Run #{run} Resource Evaluation Profiling Statistics ***\n\n".colorize(:light_blue)
  time.sort_by {|_key, value| value.to_f}.map { |l| print "\nResource: #{l[0].to_s.colorize(:green)}\nSeconds: #{l[1].to_s.colorize(:red)}\n" }
  print "\n\n*** End Run #{run} Resource Evaluation Profiling Statistics ***\n\n".colorize(:light_blue)
end

def do_puppet_runs
  print "\n\n\nRunning Puppet Agent (1/3), should return 2 (HAS CHANGES)...\n\n\n"
  ret = ssh_command(puppet_run_cmd(1), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 1)
  if ret[:exit_code] != 2
    print_errors(ret[:stderr])
    exit ret[:exit_code]
  end

  reboot_and_wait_for_host

  print "\n\n\nRunning Puppet Agent (2/3), should return 2 (HAS CHANGES)...\n\n\n"
  ret = ssh_command(puppet_run_cmd(2), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 2)
  if ret[:exit_code] != 2
    print_errors(ret[:stderr])
    exit ret[:exit_code]
  end

  print "\n\n\nRunning Puppet Agent (3/3), should return 0 (NO CHANGES OR ERRORS)...\n\n\n"
  ret = ssh_command(puppet_run_cmd(3), puppet_run: true)
  do_print_sort_eval_time(ret[:eval_time], 3)
  if ret[:exit_code] != 0
    print_errors(ret[:stderr])
  end
  exit ret
end

# Begin main script
which_os
rsync_revert
reboot_and_wait_for_host
rsync_revert
reboot_and_wait_for_host
do_puppet_runs
