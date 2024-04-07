# Generate Host Keys
ssh-keygen -A

# Must edit in /opt/etc/ssh/sshd_config
PasswordAuthentication yes
UsePAM yes
PermitRootLogin yes

# Need to add ssh user in /opt/etc/passwd
sshd:x:106:65534:Linux User,,,:/opt/run/sshd:/bin/nologin
