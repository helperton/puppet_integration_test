#!/usr/bin/env ruby

$host = ARGV[0]

def ssh_command(cmd, host = $host)
    "ssh -q -T -o ConnectTimeout=10 -o StrictHostKeyChecking=no #{host} #{cmd}"
end

puts ssh_command("ls")
