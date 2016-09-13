#!/usr/bin/env ruby

require 'net/ssh'

$host = ARGV[0]

# This guy returns a hash, exit_code (Fixnum), stdout (Array), stderr (Array)
# By default won't print output to the screen, you may turn on.
# Example: ssh_command("ls", p_stdout: true, p_stderr: true )
# Will make both stdout and stderr print out during the run
def ssh_command(cmd, options = { :p_stdout => false, :p_stderr => false })
  exit_code = 0
  stdout = Array.new
  stderr = Array.new
  Net::SSH.start($host, 'root', :paranoid => false, :timeout => 10) do |ssh|
    channel = ssh.open_channel do |ch|
      ch.exec cmd do |ch, success|
        raise "could not execute command" unless success
        # "on_data" is called when the process writes something to stdout
        ch.on_data do |c, data|
          stdout.push(data)
          $stdout.print data if options[:p_stdout]
          $stdout.flush
        end

        # "on_extended_data" is called when the process writes something to stderr
        ch.on_extended_data do |c, type, data|
          stderr.push(data)
          $stderr.print data if options[:p_stderr]
          $stderr.flush
        end

        ch.on_request("exit-status") do |c, data|
          exit_code = data.read_long
        end

        ch.on_close { print "\n\nEnding command:\n\n#{cmd}\n\nExited with code: #{exit_code}\n\n" }
      end
    end
    channel.wait
  end
  return { :exit_code => exit_code, :stdout => stdout, :stderr => stderr }
end

def which_os
  ssh_command("uname -s")[:stdout].first.chomp.downcase
end

def stop_agent
  puts "#{nls}Stopping and disabling agent!#{nls}"
  ssh_command("printf \"service { \'puppet\':\n\tensure    => \'stopped\',\n\tenable    => \'false\',\n}\n\" > /tmp/puppet-service.pp")
  ssh_command("puppet apply /tmp/puppet-service.pp")
end

def rsync_revert
  rsync_cmd = String.new

  case which_os
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
  case which_os
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

def reboot_host
  reboot_and_wait_for_host
end

def reboot_and_wait_for_host(host = $host)
  stop_agent
  puts "#{nls}Rebooting host and waiting ...#{nls}"
  ret = ssh_command("nohup #{reboot_command} &")
  puts ret
  sleep 10
  status = 1
  while status > 0
    check_if_host_rebooting(host)
    puts "#{nls}Verifying host rebooted ...#{nls}"
    ssh_command("ls >/dev/null")
    status = $?.exitstatus
    sleep 10
  end
  ret = ssh_command("ls")
  puts "#{nls}Host is back up!#{nls}"
  ret
end


# Begin main script
rsync_revert
reboot_host
