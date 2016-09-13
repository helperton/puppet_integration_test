#!/usr/bin/env ruby

$host = ARGV[0]

def ssh_command(cmd, host = $host)
  %x(ssh -q -T -o ConnectTimeout=10 -o StrictHostKeyChecking=no #{host} #{cmd})
end

ssh_command("ls")
