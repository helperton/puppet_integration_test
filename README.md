Puppet Modules Jenkins Integration Testing
==========================================

Introduction
------------

This script is intented to be used with a Jenkins job and test hosts.

When fully configured, the Jenkins job will kick off the script which will revert the host back to a clean state using rsync.  Then it will kick off 3 runs of Puppet where the first two runs must return 0 or 2 (meaning nothing changed or with changes but no errors).  The final run must exit 0 (meaning, no changes or errors).  It's designed to run every hour on the hour since runs can take 20+ minutes, it may not make sense to kick off with every commit.

The reason rsync is used is because it's cross platform and doesn't require access to the hypervisor.  It's a poor man's snaphost :)

It's primary use case is for module integration testing.  The default config also turns on evaltrace and summarizes the top 5 most expensive resources you have in your catalog.  You can then examine where your Puppet run is spending most of it's time and optimize.

The script utilizes a yaml configuration file which includes:

* excludes for os specific files and directories
* puppet agent config settings

Compatibility
-------------
Works with 4.x puppet agents, but with some changes could with with 3.8.x

Requirements for the Jenkins job
--------------------------------
plugin - Color ANSI Console Output
plugin - rbenv

![Alt text](/images/jenkins-plugins.png?raw=true "Jenkins Plugin Config")

How to import the Jenkins job
-----------------------------

1. SSH into your jenkins host
2. Switch to your jenkins user (e.g. su - jenkins -s /bin/sh)
3. cd jobs

```
cd /var/lib/jenkins/jobs
```

4. mkdir tsthost001 (e.g. tsthost001)

```
mkdir tsthost001
cd tsthost001
```

5. put the config file (config.xml -- found in the examples directory of the main repo) into this directory
6. reload Jenkins (Jenkins --> Manage Jenkins --> Reload Configuration from Disk)
7. your new job should show up
8. you will need to setup ssh key trust to your test host using Jenkins ssh identity (e.g. id_rsa.pub will need to go into /root/.ssh/authorized_keys on the test host)
9. test your connection, switch user to jenkins and try out ssh (e.g. su - jenkins -s /bin/sh ; ssh root@tsthost001)
10. if it worked, great!
11. be sure to download and enable the required plugins
12. make sure your test host is pinned to the environment or otherwise classified the way you want
13. snapshot the desired clean state of your test host
14. for linux, this is pretty good, adjust to fit your needs, add excludes for other dirs you don't want to keep such as nfs mounts

```
mkdir /var/recover
cd /var/recover
rsync -av --progress --delete --exclude /var/recover --exclude "/dev/*" --exclude "/proc/*" --exclude "/sys/*" / .
```

Examples
--------
