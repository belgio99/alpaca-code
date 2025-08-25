# Courier IMAP4/POP3/Authdaemon-MySQL
FROM debian:latest

RUN mkdir -p /var/run/courier/authdaemon/ && touch /var/run/courier/authdaemon/pid.lock
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
	courier-imap \
	courier-pop \
	courier-authlib-mysql \
	courier-mta \
	rsyslog \
	rpcbind
RUN mkdir /var/log/courier/
# mkdir is already available at /usr/bin/mkdir in Debian; no need to symlink
RUN useradd bob -d /home/bob
RUN echo bob:12345 | chpasswd
RUN mkdir /home/bob/
RUN maildirmake /home/bob/Maildir
ADD mail.eml /home/bob/Maildir/cur/1602771604.M265899P242V0000000000000036I00000000001A0657_0.f178b3e21560,S=851^%2,S
RUN chmod -R 777 /home/bob/Maildir
RUN chown -R bob:bob /home/bob
EXPOSE 110/tcp 143/tcp
ADD entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]