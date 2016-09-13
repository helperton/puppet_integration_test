#!/usr/bin/env ruby

require 'net/ssh'

$host = ARGV[0]

def ssh_command(cmd, host = $host)
  #%x(ssh -q -T -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@#{host} #{cmd})
  exit_code = 0
  Net::SSH.start(host, 'root', :paranoid => false, :timeout => 10) do |ssh|
    channel = ssh.open_channel do |ch|
      ch.exec cmd do |ch, success|
        raise "could not execute command" unless success
        # "on_data" is called when the process writes something to stdout
        ch.on_data do |c, data|
          $stdout.print data
          $stdout.flush
        end

        # "on_extended_data" is called when the process writes something to stderr
        ch.on_extended_data do |c, type, data|
          $stderr.print data
          $stderr.flush
        end

        ch.on_request("exit-status") do |c, data|
          exit_code = data.read_long
        end

        ch.on_close { puts "Ending command with exit code: #{exit_code}" }
      end
    end
    channel.wait
  end
  exit_code
end

def which_os
  ssh_command("uname -s").chomp.downcase
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
  puts ssh_command(rsync_cmd)
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
