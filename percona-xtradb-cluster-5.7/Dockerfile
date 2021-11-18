FROM percona/percona-xtradb-cluster:5.7

COPY dockerdir/entrypoint.sh /
COPY dockerdir/rainbond.sh /
COPY dockerdir/usr/local/bin/ansi /usr/local/bin

VOLUME ["/var/lib/mysql", "/var/log/mysql"]

EXPOSE 3306 4567 4568