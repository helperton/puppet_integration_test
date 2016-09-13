#!/usr/bin/env ruby

$host = ARGV[0]

def ssh_command(cmd, host = $host)
  %x(ssh -q -T -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@#{host} #{cmd})
end

puts ssh_command("ls")
