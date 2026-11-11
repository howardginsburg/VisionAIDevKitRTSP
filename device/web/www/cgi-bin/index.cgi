#!/bin/sh
# "/" of the setup page: clients of the camera's setup access point get the setup page directly;
# everyone else is sent to the login-protected page. busybox httpd listens on IPv6 and reports
# IPv4 clients as [::ffff:a.b.c.d].
addr=${REMOTE_ADDR#[}; addr=${addr%]}; addr=${addr#::ffff:}
case "$addr" in
    192.168.143.*) exec /bin/sh /opt/vaidk/web/ui.sh ap ;;
esac
exec /bin/sh /opt/vaidk/web/ui.sh entry
